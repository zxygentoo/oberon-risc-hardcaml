(* Public API and behaviour spec live in [fp_divider.mli].

   Implementation note. A *sequential* unit, so per AGENT.md §2 we mirror RISC5.v's
   skeleton exactly: the registered signals (the 24-bit remainder [R], the 26-bit quotient
   [Q] and the 5-bit state [S]) and the stall timing are the spec the oracle checks
   cycle-by-cycle and synthesis preserves; the combinational FP wrapper is idiomatic
   Hardcaml. The original RTL is [_po/verilog/src/FPDivider.v] (45 lines).

   Restoring division — the dual of the integer/FP multiplier's shift-and-add. Each step
   doubles the remainder ([{R, 1'b0}], a left shift) and trial-subtracts the divisor
   ([d = r0 - 1.y]). The borrow [d[24]] decides: if the divisor didn't fit the subtraction
   goes negative, so we *restore* the old remainder ([r1 = d[24] ? r0 : d]) and the
   quotient bit is 0; otherwise we keep the difference and the bit is 1. [Q] shifts that
   bit ([~d[24]]) in from the LSB each cycle, MSB-first, so after the 26 steps [Q[25]] is
   the first bit (whether the quotient >= 1) and drives normalization. [S=0] loads [x]'s
   mantissa as the initial remainder; [run] gates [S] (run=0 -> S:=0), so there is no
   reset.

   The wrinkle vs the multiplier (whose [P] feedback was a self-contained reg_fb): [R]'s
   next value and [Q]'s next bit both come from the *same* trial subtraction [d], and [d]
   is a function of the current [R]. So we forward-declare [R] and [Q] as wires, build the
   combinational step off them, and close the loop by assigning each through a [reg] — the
   register breaks the apparent cycle. (Equivalently one combined 50-bit register: the
   same flip-flops as the RTL's two.)

   The FP wrapper is combinational off [Q] and the held inputs, structurally a copy of the
   multiplier's: [sign] is the XOR of the operand signs; [e1 = xe - ye + 126 + Q[25]]
   subtracts the exponents (cancelling the bias), re-adds it, and folds in the normalize
   shift; [z0] normalizes on [Q[25]] and [z1] rounds; and [z] repacks, mapping a zero
   dividend (-> 0), a zero divisor (-> signed inf), exponent overflow (-> inf) and
   underflow (-> 0). *)

open! Base
open Hardcaml
open Signal

module I = struct
  type 'a t =
    { clock : 'a
    ; run : 'a [@bits 1]
    ; x : 'a [@bits 32]
    ; y : 'a [@bits 32]
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { stall : 'a [@bits 1]
    ; z : 'a [@bits 32]
    }
  [@@deriving hardcaml]
end

let create (i : _ I.t) : _ O.t =
  let spec = Reg_spec.create () ~clock:i.clock in
  (* S : 5-bit state counter; [run] is both enable and synchronous clear (no reset). *)
  let s = reg_fb spec ~width:5 ~f:(fun s -> mux2 i.run (s +:. 1) (zero 5)) in
  (* a 24-bit mantissa (restored hidden bit + frac) in a 25-bit field, top bit 0 (room for
     the trial-subtraction borrow) *)
  let mant25 v = gnd @: vdd @: select v ~high:22 ~low:0 in
  (* R (24-bit remainder) and Q (26-bit quotient): forward-declared, assigned through reg
     below so the restoring step can read the current values. *)
  let r = wire 24 in
  let q = wire 26 in
  (* ---- restoring-division step (combinational, off the current R) ---- *)
  (* double the remainder (shift left one), then trial-subtract the divisor; d's top bit
     is the borrow *)
  let r0 = mux2 (s ==:. 0) (mant25 i.x) (r @: gnd) in
  let d = r0 -: mant25 i.y in
  (* on borrow the divisor didn't fit: restore the old remainder, quotient bit 0 *)
  let r1 = mux2 (msb d) r0 d in
  let q0 = mux2 (s ==:. 0) (zero 26) q in
  assign r (reg spec (select r1 ~high:23 ~low:0));
  (* shift the quotient bit [~d[24]] in from the LSB *)
  assign q (reg spec (select q0 ~high:24 ~low:0 @: ~:(msb d)));
  (* ---- combinational FP wrapper off the held inputs + Q ---- *)
  let sign = msb i.x ^: msb i.y in
  let xe = select i.x ~high:30 ~low:23 in
  let ye = select i.y ~high:30 ~low:23 in
  let e0 = uresize xe ~width:9 -: uresize ye ~width:9 in
  (* subtracting the exponents cancels the bias, so re-add it; [Q[25]] folds in the
     normalize shift *)
  let e1 = e0 +:. 126 +: uresize (msb q) ~width:9 in
  (* normalize on Q[25] (quotient >= 1), then round *)
  let z0 = mux2 (msb q) (select q ~high:25 ~low:1) (select q ~high:24 ~low:0) in
  let z1 = z0 +:. 1 in
  let normal = sign @: select e1 ~high:7 ~low:0 @: select z1 ~high:23 ~low:1 in
  let inf = sign @: ones 8 @: zero 23 in
  (* divide-by-zero infinity *)
  let inf_ov = sign @: ones 8 @: select z0 ~high:23 ~low:1 in
  (* overflow infinity *)
  (* zero dividend -> 0; zero divisor -> signed inf; exponent in range -> normal; overflow
     -> inf; underflow -> 0 *)
  let z =
    mux2
      (xe ==:. 0)
      (zero 32)
      (mux2
         (ye ==:. 0)
         inf
         (mux2 ~:(msb e1) normal (mux2 ~:(select e1 ~high:7 ~low:7) inf_ov (zero 32))))
  in
  { O.stall = i.run &: ~:(s ==:. 26); z }
;;

(* ── Tests (co-located; AGENT.md §6) ──────────────────────────────────────────
   Value-correctness is the verilator RTL co-sim's job (test/cosim/, the §6 fidelity
   oracle): it proves bit-exactness to FPDivider.v over the frozen fp_vectors D-lines +
   fuzz. What we pin here is the cycle timing plus one oracle-free sanity value: the 5-bit
   state walks 0->26, stall holds for States 0..25 then drops at S==26, and a plain FDV
   6.0 / 2.0 = 3.0 (0x40400000). Like {!Fp_multiplier}, the 26-cycle run is too long for
   one window, so two tight windows — the head (run -> stall asserts) and the tail (stall
   drops, run releases) — bracket the uniform stall=1 middle. *)

let%expect_test "FPDivider timing — stall envelope (S 0->26) + FDV 6.0 / 2.0 = 3.0" =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let module Waveform = Hardcaml_waveterm.For_cyclesim.Waveform in
  let module D = Hardcaml_waveterm.Display_rule in
  let sim = Sim.create create in
  let waves, sim = Waveform.create sim in
  let inp = Cyclesim.inputs sim in
  let outp = Cyclesim.outputs sim in
  let set r v w = r := Bits.of_unsigned_int ~width:w v in
  (* one idle cycle so the run/stall rising edges show, then a FDV run with operands held
     stable across the run (as the core guarantees); z is read when stall drops (S==26),
     then run releases the next cycle, exactly as the core sequences it. *)
  set inp.x 0x40C0_0000 32;
  set inp.y 0x4000_0000 32;
  set inp.run 0 1;
  Cyclesim.cycle sim;
  set inp.run 1 1;
  Cyclesim.cycle sim;
  while Bits.to_int_trunc !(outp.stall) = 1 do
    Cyclesim.cycle sim
  done;
  let z_result = Bits.to_unsigned_int !(outp.z) in
  set inp.run 0 1;
  Cyclesim.cycle sim;
  let rules =
    D.
      [ port_name_is ~wave_format:Wave_format.Bit "run"
      ; port_name_is ~wave_format:Wave_format.Hex "x"
      ; port_name_is ~wave_format:Wave_format.Hex "y"
      ; port_name_is ~wave_format:Wave_format.Bit "stall"
      ]
  in
  (* head: idle -> run asserts -> stall asserts (the load + first iterations) *)
  Waveform.print ~display_rules:rules ~start_cycle:0 ~wave_width:4 ~display_width:62 waves;
  [%expect
    {|
    ┌Signals──────┐┌Waves────────────────────────────────────────┐
    │run          ││          ┌──────────────────────────────────│
    │             ││──────────┘                                  │
    │             ││─────────────────────────────────────────────│
    │x            ││ 40C00000                                    │
    │             ││─────────────────────────────────────────────│
    │             ││─────────────────────────────────────────────│
    │y            ││ 40000000                                    │
    │             ││─────────────────────────────────────────────│
    │stall        ││          ┌──────────────────────────────────│
    │             ││──────────┘                                  │
    └─────────────┘└─────────────────────────────────────────────┘
    |}];
  (* tail: stall drops at S==26, run releases (the 26-cycle middle is uniform stall=1) *)
  Waveform.print
    ~display_rules:rules
    ~start_cycle:24
    ~wave_width:4
    ~display_width:62
    waves;
  [%expect
    {|
    ┌Signals──────┐┌Waves────────────────────────────────────────┐
    │run          ││──────────────────────────────┐              │
    │             ││                              └─────────     │
    │             ││────────────────────────────────────────     │
    │x            ││ 40C00000                                    │
    │             ││────────────────────────────────────────     │
    │             ││────────────────────────────────────────     │
    │y            ││ 40000000                                    │
    │             ││────────────────────────────────────────     │
    │stall        ││──────────────────────────────┐              │
    │             ││                              └─────────     │
    └─────────────┘└─────────────────────────────────────────────┘
    |}];
  Stdlib.Printf.printf "FDV 6.0 / 2.0  ->  z = 0x%08X\n" z_result;
  [%expect {| FDV 6.0 / 2.0  ->  z = 0x40400000 |}]
;;

(* Public API and behaviour spec live in [fp_multiplier.mli].

   Implementation note. A *sequential* unit, so per AGENT.md §2 we mirror RISC5.v's
   skeleton exactly: the registered signals (the 48-bit product [P] and the 5-bit state
   [S]) and the stall timing are the spec the oracle checks cycle-by-cycle and synthesis
   preserves; the combinational FP wrapper between the register boundaries is idiomatic
   Hardcaml. The original RTL is [_po/verilog/src/FPMultiplier.v] (34 lines); each line
   below is tagged with the wire it ports.

   The mantissa engine is the integer {!Multiplier} in miniature. [P] is a 48-bit
   dual-role register: its low half holds [x]'s 24-bit mantissa being consumed (LSB =
   current bit), its high half is the running accumulator. Each step gates [y]'s mantissa
   by [P[0]], adds it to the top 24 bits (a 25-bit add whose carry becomes the new MSB),
   then shifts the whole register right by one — so [x]'s mantissa slides out the bottom
   and product bits fill in from the top. After the 24 iterations [P] holds the full
   48-bit mantissa product. [S] sequences it: [S=0] loads, S=1..24 accumulate/shift, S=25
   ends; [run] gates [S] (run=0 -> S:=0), so there is no reset.

   The FP wrapper is combinational off [P] and the held inputs: [sign] is the XOR of the
   operand signs; [e1 = xe + ye - 127 + P[47]] removes one exponent bias and bumps by one
   when the product reached bit 47 (>= 2.0); [z0] rounds (the [+1]) from bit 47 or 46
   depending on that carry; and [z] repacks [{sign, exponent, mantissa}], mapping a zero
   operand, exponent overflow (-> inf) and underflow (-> 0) exactly as the RTL's nested
   ternary. *)

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
  (* P : 48-bit dual-role register (hi = accumulator, lo = x's mantissa). [s] is in scope,
     so P's feedback can test S==0 for the load. *)
  let p =
    reg_fb spec ~width:48 ~f:(fun p ->
      let w0 = mux2 (lsb p) (vdd @: select i.y ~high:22 ~low:0) (zero 24) in
      (* P[0] ? {1'b1, y[22:0]} : 0 *)
      let w1 = uresize (select p ~high:47 ~low:24) ~width:25 +: uresize w0 ~width:25 in
      (* {1'b0, P[47:24]} + {1'b0, w0} *)
      mux2
        (s ==:. 0)
        (zero 24 @: vdd @: select i.x ~high:22 ~low:0) (* load {24'b0, 1'b1, x[22:0]} *)
        (w1 @: select p ~high:23 ~low:1)
      (* {w1, P[23:1]} *))
  in
  (* ---- combinational FP wrapper off the held inputs + P ---- *)
  let sign = msb i.x ^: msb i.y in
  let xe = select i.x ~high:30 ~low:23 in
  let ye = select i.y ~high:30 ~low:23 in
  let e0 = uresize xe ~width:9 +: uresize ye ~width:9 in
  (* xe + ye *)
  let e1 = e0 -:. 127 +: uresize (msb p) ~width:9 in
  (* e0 - 127 + P[47] *)
  let z0 =
    mux2 (msb p) (select p ~high:47 ~low:23 +:. 1) (select p ~high:46 ~low:22 +:. 1)
  in
  (* P[47] ? P[47:23]+1 : P[46:22]+1 — round and normalize *)
  let mant = select z0 ~high:23 ~low:1 in
  (* z0[23:1] *)
  let normal = sign @: select e1 ~high:7 ~low:0 @: mant in
  (* {sign, e1[7:0], z0[23:1]} *)
  let inf = sign @: ones 8 @: mant in
  (* {sign, 8'b11111111, z0[23:1]} *)
  let z =
    mux2
      (xe ==:. 0 |: (ye ==:. 0))
      (zero 32) (* xe==0 | ye==0 *)
      (mux2
         ~:(msb e1)
         normal (* ~e1[8] : exponent in range *)
         (mux2 ~:(select e1 ~high:7 ~low:7) inf (zero 32)))
    (* ~e1[7] : overflow -> inf, else underflow -> 0 *)
  in
  { O.stall = i.run &: ~:(s ==:. 25); z }
;;

(* ── Tests (co-located; AGENT.md §6) ──────────────────────────────────────────
   Value-correctness is the verilator RTL co-sim's job (test/cosim/, the §6 fidelity
   oracle): it proves bit-exactness to FPMultiplier.v over the frozen fp_vectors M-lines +
   fuzz. What we pin here is the cycle timing plus one oracle-free sanity value: the 5-bit
   state walks 0->25, stall holds for States 0..24 then drops at S==25, and a plain FML
   2.0 * 2.0 = 4.0 (0x40800000). Like {!Multiplier}, the 25-cycle run is too long for one
   window, so two tight windows — the head (run -> stall asserts) and the tail (stall
   drops, run releases) — bracket the uniform stall=1 middle. *)

let%expect_test "FPMultiplier timing — stall envelope (S 0->25) + FML 2.0 * 2.0 = 4.0" =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let module Waveform = Hardcaml_waveterm.For_cyclesim.Waveform in
  let module D = Hardcaml_waveterm.Display_rule in
  let sim = Sim.create create in
  let waves, sim = Waveform.create sim in
  let inp = Cyclesim.inputs sim in
  let outp = Cyclesim.outputs sim in
  let set r v w = r := Bits.of_unsigned_int ~width:w v in
  (* one idle cycle so the run/stall rising edges show, then a FML run with operands held
     stable across the run (as the core guarantees); z is read when stall drops (S==25),
     then run releases the next cycle, exactly as the core sequences it. *)
  set inp.x 0x4000_0000 32;
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
    │x            ││ 40000000                                    │
    │             ││─────────────────────────────────────────────│
    │             ││─────────────────────────────────────────────│
    │y            ││ 40000000                                    │
    │             ││─────────────────────────────────────────────│
    │stall        ││          ┌──────────────────────────────────│
    │             ││──────────┘                                  │
    └─────────────┘└─────────────────────────────────────────────┘
    |}];
  (* tail: stall drops at S==25, run releases (the 25-cycle middle is uniform stall=1) *)
  Waveform.print
    ~display_rules:rules
    ~start_cycle:23
    ~wave_width:4
    ~display_width:62
    waves;
  [%expect
    {|
    ┌Signals──────┐┌Waves────────────────────────────────────────┐
    │run          ││──────────────────────────────┐              │
    │             ││                              └─────────     │
    │             ││────────────────────────────────────────     │
    │x            ││ 40000000                                    │
    │             ││────────────────────────────────────────     │
    │             ││────────────────────────────────────────     │
    │y            ││ 40000000                                    │
    │             ││────────────────────────────────────────     │
    │stall        ││──────────────────────────────┐              │
    │             ││                              └─────────     │
    └─────────────┘└─────────────────────────────────────────────┘
    |}];
  Stdlib.Printf.printf "FML 2.0 * 2.0  ->  z = 0x%08X\n" z_result;
  [%expect {| FML 2.0 * 2.0  ->  z = 0x40800000 |}]
;;

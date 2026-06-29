(* Public API and behaviour spec live in [fp_multiplier.mli].

   Implementation note. A *sequential* unit, so per AGENT.md §2 we mirror RISC5.v's
   skeleton exactly: the registered signals (the 48-bit product [P] and the 5-bit state
   [S]) and the stall timing are the spec the oracle checks cycle-by-cycle and synthesis
   preserves; the combinational FP wrapper between the register boundaries is idiomatic
   Hardcaml. The original RTL is [test/_po/verilog/src/FPMultiplier.v] (34 lines).

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

let create ?(ce = vdd) (i : _ I.t) : _ O.t =
  let spec = Reg_spec.create () ~clock:i.clock in
  (* Phase 7: ce-gate the unit's state so it freezes with the ce-gated core during a
     multi-cycle PSRAM wait (else the counter overruns the fetch-wait and the op restarts
     — see [Divider]). [ce = vdd] (the default) ⇒ byte-identical. *)
  let reg_fb spec ~width ~f = Signal.reg_fb spec ~enable:ce ~width ~f in
  (* S : 5-bit state counter; [run] is both enable and synchronous clear (no reset). *)
  (* Registers named to match the RTL ([S]/[P]) so the Phase-8 formal harness can pair the
     flip-flops with FPMultiplier.v's (yosys [equiv_make] matches FFs by name —
     test/formal), exactly as the integer Multiplier names its [S]/[P]. *)
  let s = reg_fb spec ~width:5 ~f:(fun s -> mux2 i.run (s +:. 1) (zero 5)) -- "S" in
  (* P : 48-bit dual-role register (hi = accumulator, lo = x's mantissa). [s] is in scope,
     so P's feedback can test S==0 for the load. *)
  let p =
    reg_fb spec ~width:48 ~f:(fun p ->
      (* y's mantissa (with restored hidden bit), gated by the current x-mantissa bit P[0] *)
      let w0 = mux2 (lsb p) (vdd @: select i.y ~high:22 ~low:0) (zero 24) in
      (* 25-bit add of the accumulator's top 24 bits, the carry becoming the new MSB *)
      let w1 = uresize (select p ~high:47 ~low:24) ~width:25 +: uresize w0 ~width:25 in
      (* S=0 loads x's mantissa into the low half; else accumulate-then-shift-right-by-one *)
      mux2
        (s ==:. 0)
        (zero 24 @: vdd @: select i.x ~high:22 ~low:0)
        (w1 @: select p ~high:23 ~low:1))
    -- "P"
  in
  (* ---- combinational FP wrapper off the held inputs + P ---- *)
  let sign = msb i.x ^: msb i.y in
  let xe = select i.x ~high:30 ~low:23 in
  let ye = select i.y ~high:30 ~low:23 in
  let e0 = uresize xe ~width:9 +: uresize ye ~width:9 in
  (* remove one exponent bias; bump by one when the product reached bit 47 (>= 2.0) *)
  let e1 = e0 -:. 127 +: uresize (msb p) ~width:9 in
  (* round (+1) and normalize, from bit 47 or 46 depending on that carry *)
  let z0 =
    mux2 (msb p) (select p ~high:47 ~low:23 +:. 1) (select p ~high:46 ~low:22 +:. 1)
  in
  let mant = select z0 ~high:23 ~low:1 in
  let normal = sign @: select e1 ~high:7 ~low:0 @: mant in
  let inf = sign @: ones 8 @: mant in
  (* a zero operand -> 0; exponent in range -> normal; overflow -> inf; underflow -> 0
     (the borrow/sign bits of e1 distinguish the three exponent cases) *)
  let z =
    mux2
      (xe ==:. 0 |: (ye ==:. 0))
      (zero 32)
      (mux2 ~:(msb e1) normal (mux2 ~:(select e1 ~high:7 ~low:7) inf (zero 32)))
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

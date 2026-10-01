(* A port of FPDivider.v; the contract is in [fp_divider.mli].

   Restoring division. Each step doubles the remainder and subtracts the divisor on trial.
   If the subtraction borrows, the divisor did not fit: the old remainder is kept and the
   quotient bit is 0. Otherwise the difference is kept and the bit is 1. [Q] takes the bit
   in at the bottom, so after the 26 steps [Q[25]] is the first bit — whether the quotient
   reached 1 — and decides the normalisation.

   [R]'s next value and [Q]'s next bit come from the same trial subtraction, which is a
   function of the current [R]. So both are declared as wires, the step is built from
   them, and each is closed through a register.

   Around the divider, combinationally and much as in the multiplier: the sign, the
   exponent [xe - ye + 126 + Q[25]], normalising on [Q[25]], rounding, and the special
   cases — a zero dividend gives 0, a zero divisor a signed infinity, overflow infinity,
   underflow 0. *)

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
  (* the state freezes with the core under [ce]; see [Divider] *)
  let reg_fb spec ~width ~f = Signal.reg_fb spec ~enable:ce ~width ~f in
  let reg spec d = Signal.reg spec ~enable:ce d in
  (* [run] is the enable and the synchronous clear. The registers carry the RTL's names,
     [S], [R] and [Q] — put on the register outputs, not on the wires, so that it is the
     flip-flops that are named: the equivalence proof pairs registers by name. *)
  let s = reg_fb spec ~width:5 ~f:(fun s -> mux2 i.run (s +:. 1) (zero 5)) -- "S" in
  (* a 24-bit mantissa (restored hidden bit + frac) in a 25-bit field, top bit 0 (room for
     the trial-subtraction borrow) *)
  let mant25 v = gnd @: vdd @: select v ~high:22 ~low:0 in
  let r = wire 24 in
  let q = wire 26 in
  (* double the remainder, then subtract the divisor on trial; the top bit of [d] is the
     borrow *)
  let r0 = mux2 (s ==:. 0) (mant25 i.x) (r @: gnd) in
  let d = r0 -: mant25 i.y in
  (* on borrow the divisor didn't fit: restore the old remainder, quotient bit 0 *)
  let r1 = mux2 (msb d) r0 d in
  let q0 = mux2 (s ==:. 0) (zero 26) q in
  assign r (reg spec (select r1 ~high:23 ~low:0) -- "R");
  (* shift the quotient bit [~d[24]] in from the LSB *)
  assign q (reg spec (select q0 ~high:24 ~low:0 @: ~:(msb d)) -- "Q");
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

(* ── Tests ── The values are checked against FPDivider.v by the co-simulation, and
   against the frozen vectors in test/. Here: the timing ([S] walks from 0 to 26 and
   [stall] drops at 26) and one value, 6.0 / 2.0. *)

let%expect_test "FPDivider timing — stall envelope (S 0->26) + FDV 6.0 / 2.0 = 3.0" =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let module Waveform = Hardcaml_waveterm.Waveform in
  let module D = Hardcaml_waveterm.Display_rule in
  let sim = Sim.create create in
  let waves, sim = Cyclesim.Waveform.create sim in
  let inp = Cyclesim.inputs sim in
  let outp = Cyclesim.outputs sim in
  let set r v w = r := Bits.of_unsigned_int ~width:w v in
  (* one idle cycle, then FDV with the operands held; [z] is read when [stall] drops, and
     [run] is released on the next cycle, as the core does *)
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

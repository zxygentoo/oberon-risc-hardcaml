(* Public API and behaviour spec live in [fp_adder.mli].

   Implementation note. A pipelined sequential unit, so per AGENT.md §2 we mirror RISC5.v's
   skeleton exactly: the registered signals (the three pipeline stages x3/y3, Sum, t3, plus
   the 2-bit State) and the stall timing are the spec the oracle checks and synthesis
   preserves; the combinational datapath between the register boundaries is idiomatic
   Hardcaml. Original RTL is [po/verilog/src/FPAdder.v] (132 lines); each block below is
   tagged with the stage it implements.

   The pipeline. Stage 0 unpacks x/y into sign, 8-bit exponent and 25-bit mantissa (restored
   hidden bit + a low guard bit), takes the exponent difference to pick the larger exponent
   e0 and the right-shift counts, converts the smaller operand to two's complement and
   denormalizes it, registering x3/y3. Stage 1 registers Sum = sext(x3) + sext(y3). Stage 2
   converts Sum back to sign-magnitude and rounds (s = |Sum| + 1, the +1 acting on the guard
   bit), finds the leading one with the z24..z2 detector to get the post-normalize shift
   count sc, shifts s left into t3, and adjusts the exponent e1 = e0 - sc + 1. The output
   repacks {sign, e1, t3}, or sign-extends Sum[25:1] for FLOOR, with the zero / FLT-null
   cases handled explicitly.

   Two idiom choices (§2). The barrel shifts (denormalize, post-normalize) are radix-4 staged
   in the RTL; here they are log_shift. The denormalize fills with the operand sign rather
   than the value's MSB, so it is an arithmetic shift of {sign, mantissa} truncated back to
   25 bits — equivalent to the RTL's {{n{xs}}, ...} fills, saturating to all-sign past 32.
   The leading-one detector and shift-count encoder, by contrast, are transliterated bit for
   bit (a priority encoder is exactly where an idiomatic rewrite could silently diverge). *)

open! Base
open Hardcaml
open Signal

module I = struct
  type 'a t =
    { clock : 'a
    ; run : 'a [@bits 1]
    ; u : 'a [@bits 1]
    ; v : 'a [@bits 1]
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
  (* Sequential skeleton (final): 2-bit State, run-gated with no reset, stall = run &
     ~(S==3). *)
  let state = reg_fb spec ~width:2 ~f:(fun s -> mux2 i.run (s +:. 1) (zero 2)) in
  let stall = i.run &: ~:(state ==:. 3) in
  (* ---- unpack (combinational off the held inputs) ---- *)
  let xs = msb i.x in
  (* sign *)
  let ys = msb i.y in
  let xe = mux2 i.u (of_unsigned_int ~width:8 0x96) (select i.x ~high:30 ~low:23) in
  (* u ? 8'h96 : x[30:23] *)
  let ye = select i.y ~high:30 ~low:23 in
  let xm =
    (~:(i.u) |: select i.x ~high:23 ~low:23) @: select i.x ~high:22 ~low:0 @: gnd
  in
  (* {~u|x[23], x[22:0], 0} : restored hidden bit + guard *)
  let ym = (~:(i.u) &: ~:(i.v)) @: select i.y ~high:22 ~low:0 @: gnd in
  (* {~u&~v, y[22:0], 0} *)
  let xn = select i.x ~high:30 ~low:0 ==:. 0 in
  (* x[30:0]==0 : null *)
  let yn = select i.y ~high:30 ~low:0 ==:. 0 in
  (* ---- exponent difference -> larger exponent e0 + the two right-shift counts ---- *)
  let dx = uresize xe ~width:9 -: uresize ye ~width:9 in
  let dy = uresize ye ~width:9 -: uresize xe ~width:9 in
  let e0 = mux2 (msb dx) (uresize ye ~width:9) (uresize xe ~width:9) in
  (* dx[8] ? ye : xe *)
  let sx = mux2 (msb dy) (zero 8) (select dy ~high:7 ~low:0) in
  (* dy[8] ? 0 : dy *)
  let sy = mux2 (msb dx) (zero 8) (select dx ~high:7 ~low:0) in
  (* ---- Stage 0: two's-complement convert + denormalize the smaller operand -> x3, y3
     ---- *)
  (* arithmetic right shift of [{sign, mantissa}] by [by], truncated to 25 bits (fills
     with the operand sign; saturates to all-sign past 32) — the RTL's staged radix-4
     shifter *)
  let denorm m ~sign ~by = select (log_shift ~f:sra (sign @: m) ~by) ~high:24 ~low:0 in
  let x0 = mux2 (xs &: ~:(i.u)) (negate xm) xm in
  (* xs&~u ? -xm : xm *)
  let y0 = mux2 (ys &: ~:(i.u)) (negate ym) ym in
  let x3 = reg spec (denorm x0 ~sign:xs ~by:sx) in
  let y3 = reg spec (denorm y0 ~sign:ys ~by:sy) in
  (* ---- Stage 1: two's-complement add -> Sum ---- *)
  let sum = reg spec ((xs @: xs @: x3) +: (ys @: ys @: y3)) in
  (* {xs,xs,x3} + {ys,ys,y3} *)
  (* ---- Stage 2: sign-magnitude + guard round, leading-one detect, post-normalize ---- *)
  let s = mux2 (msb sum) (negate sum) sum +:. 1 in
  (* (Sum[26] ? -Sum : Sum) + 1 *)
  let sb n = select s ~high:n ~low:n in
  (* leading-one detector: z(2k) is high iff s[25:2k] are all zero *)
  let z24 = ~:(sb 25) &: ~:(sb 24) in
  let z22 = z24 &: ~:(sb 23) &: ~:(sb 22) in
  let z20 = z22 &: ~:(sb 21) &: ~:(sb 20) in
  let z18 = z20 &: ~:(sb 19) &: ~:(sb 18) in
  let z16 = z18 &: ~:(sb 17) &: ~:(sb 16) in
  let z14 = z16 &: ~:(sb 15) &: ~:(sb 14) in
  let z12 = z14 &: ~:(sb 13) &: ~:(sb 12) in
  let z10 = z12 &: ~:(sb 11) &: ~:(sb 10) in
  let z8 = z10 &: ~:(sb 9) &: ~:(sb 8) in
  let z6 = z8 &: ~:(sb 7) &: ~:(sb 6) in
  let z4 = z6 &: ~:(sb 5) &: ~:(sb 4) in
  let z2 = z4 &: ~:(sb 3) &: ~:(sb 2) in
  (* shift count sc, MSB..LSB (the RTL's sc[4]..sc[0]) *)
  let sc4 = z10 in
  let sc3 =
    z18 &: (sb 17 |: sb 16 |: sb 15 |: sb 14 |: sb 13 |: sb 12 |: sb 11 |: sb 10) |: z2
  in
  let sc2 =
    z22
    &: (sb 21 |: sb 20 |: sb 19 |: sb 18)
    |: (z14 &: (sb 13 |: sb 12 |: sb 11 |: sb 10))
    |: (z6 &: (sb 5 |: sb 4 |: sb 3 |: sb 2))
  in
  let sc1 =
    z24
    &: (sb 23 |: sb 22)
    |: (z20 &: (sb 19 |: sb 18))
    |: (z16 &: (sb 15 |: sb 14))
    |: (z12 &: (sb 11 |: sb 10))
    |: (z8 &: (sb 7 |: sb 6))
    |: (z4 &: (sb 3 |: sb 2))
  in
  let sc0 =
    ~:(sb 25)
    &: sb 24
    |: (z24 &: ~:(sb 23) &: sb 22)
    |: (z22 &: ~:(sb 21) &: sb 20)
    |: (z20 &: ~:(sb 19) &: sb 18)
    |: (z18 &: ~:(sb 17) &: sb 16)
    |: (z16 &: ~:(sb 15) &: sb 14)
    |: (z14 &: ~:(sb 13) &: sb 12)
    |: (z12 &: ~:(sb 11) &: sb 10)
    |: (z10 &: ~:(sb 9) &: sb 8)
    |: (z8 &: ~:(sb 7) &: sb 6)
    |: (z6 &: ~:(sb 5) &: sb 4)
    |: (z4 &: ~:(sb 3) &: sb 2)
  in
  let sc = sc4 @: sc3 @: sc2 @: sc1 @: sc0 in
  let e1 = e0 -: uresize sc ~width:9 +:. 1 in
  let t3 = reg spec (log_shift ~f:sll (select s ~high:25 ~low:1) ~by:sc) in
  (* ---- output assembly ---- *)
  let floor_z = sresize (select sum ~high:26 ~low:1) ~width:32 in
  (* {{7{Sum[26]}}, Sum[25:1]} *)
  let normal_z = msb sum @: select e1 ~high:7 ~low:0 @: select t3 ~high:23 ~low:1 in
  (* {Sum[26], e1[7:0], t3[23:1]} *)
  let z =
    mux2
      i.v
      floor_z (* FLOOR *)
      (mux2
         xn
         (mux2 (i.u |: yn) (zero 32) i.y) (* FLT or x = y = 0 *)
         (mux2 yn i.x (* y = 0 *) (mux2 (t3 ==:. 0 |: msb e1) (zero 32) normal_z)))
  in
  { O.stall; z }
;;

(* ── Tests (co-located; AGENT.md §6) ──────────────────────────────────────────
   Value-correctness — the frozen [fp_vectors.txt] replay — is oracle-coupled (it reads
   the vendored vectors), so it lives in [test/test_fp_adder.ml]. What we pin here is the
   cycle timing plus one oracle-free sanity value: the 2-bit State walks 0->3, stall holds
   for States 0..2 then drops at State==3, and a plain FAD 1.0 + 1.0 = 2.0 (0x40000000). *)

let%expect_test "FPAdder timing — stall envelope (State 0->3) + FAD 1.0 + 1.0 = 2.0" =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let module Waveform = Hardcaml_waveterm.For_cyclesim.Waveform in
  let module D = Hardcaml_waveterm.Display_rule in
  let sim = Sim.create create in
  let waves, sim = Waveform.create sim in
  let inp = Cyclesim.inputs sim in
  let outp = Cyclesim.outputs sim in
  let set r v w = r := Bits.of_unsigned_int ~width:w v in
  (* one idle cycle so the run/stall rising edges show, then a FAD run (u=v=0) with
     operands held stable across the run (as the core guarantees); z is read when stall
     drops (State 3), then run releases the next cycle, exactly as the core sequences it. *)
  set inp.u 0 1;
  set inp.v 0 1;
  set inp.x 0x3F80_0000 32;
  set inp.y 0x3F80_0000 32;
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
      ; port_name_is ~wave_format:Wave_format.Bit "stall"
      ; port_name_is ~wave_format:Wave_format.Hex "z"
      ]
  in
  Waveform.print ~display_rules:rules ~start_cycle:0 ~wave_width:4 ~display_width:72 waves;
  Stdlib.Printf.printf "FAD 1.0 + 1.0  ->  z = 0x%08X\n" z_result;
  [%expect
    {|
    ┌Signals─────────┐┌Waves───────────────────────────────────────────────┐
    │run             ││          ┌─────────────────────────────┐           │
    │                ││──────────┘                             └─────────  │
    │stall           ││          ┌─────────────────────────────┐           │
    │                ││──────────┘                             └─────────  │
    │                ││──────────────────────────────┬───────────────────  │
    │z               ││ 00000000                     │40000000             │
    │                ││──────────────────────────────┴───────────────────  │
    └────────────────┘└────────────────────────────────────────────────────┘
    FAD 1.0 + 1.0  ->  z = 0x40000000
    |}]
;;

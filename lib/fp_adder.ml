(* A port of FPAdder.v; the contract is in [fp_adder.mli].

   The registers are the RTL's: the pipeline stages [x3]/[y3], [Sum] and [t3], and the
   counter [State]. Stage 0 unpacks the operands, takes the exponent difference to find
   the larger exponent [e0] and the two shift counts, converts each operand to two's
   complement and shifts the smaller one right. Stage 1 adds. Stage 2 goes back to sign
   and magnitude and rounds (the +1 acts on the guard bit), finds the leading 1, shifts it
   up to the hidden-bit position and adjusts the exponent. The output repacks sign,
   exponent and mantissa — or, for FLOOR, sign-extends the sum — with zero handled
   explicitly.

   The two barrel shifts are staged in the RTL and are [log_shift] here. The alignment
   shift fills with the operand's sign, so it is an arithmetic shift of
   [{sign, mantissa}]. The leading-one detector and its shift-count encoder are
   transliterated bit for bit: a priority encoder is exactly where a rewrite could differ
   without anyone noticing. *)

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

(* The shift count for renormalising. The rounded magnitude [s] has its leading 1
   somewhere in [s[25:2]]; [z(2k)] is high when [s[25:2k]] are all zero, and the count
   says how far left to shift so that the 1 lands on the hidden bit. Bit for bit from the
   RTL. *)
let shift_count s =
  let sb n = select s ~high:n ~low:n in
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
  sc4 @: sc3 @: sc2 @: sc1 @: sc0
;;

let create ?(ce = vdd) (i : _ I.t) : _ O.t =
  let spec = Reg_spec.create () ~clock:i.clock in
  (* the state freezes with the core under [ce]; see [Divider] *)
  let reg_fb spec ~width ~f = Signal.reg_fb spec ~enable:ce ~width ~f in
  let reg spec d = Signal.reg spec ~enable:ce d in
  (* [run] is the enable and the synchronous clear. The registers carry the RTL's names:
     the equivalence proof pairs registers by name. *)
  let state =
    reg_fb spec ~width:2 ~f:(fun s -> mux2 i.run (s +:. 1) (zero 2)) -- "State"
  in
  let stall = i.run &: ~:(state ==:. 3) in
  (* ---- unpack (combinational off the held inputs) ---- *)
  let xs = msb i.x in
  let ys = msb i.y in
  (* FLT feeds the integer through with a fixed exponent (0x96 = 150 = 2^23's bias) *)
  let xe = mux2 i.u (of_unsigned_int ~width:8 0x96) (select i.x ~high:30 ~low:23) in
  let ye = select i.y ~high:30 ~low:23 in
  (* 25-bit mantissa: restored hidden bit (forced for FLT) + low guard bit *)
  let xm =
    (~:(i.u) |: select i.x ~high:23 ~low:23) @: select i.x ~high:22 ~low:0 @: gnd
  in
  let ym = (~:(i.u) &: ~:(i.v)) @: select i.y ~high:22 ~low:0 @: gnd in
  (* null operands (exponent and fraction both zero) — masked into the output below *)
  let xn = select i.x ~high:30 ~low:0 ==:. 0 in
  let yn = select i.y ~high:30 ~low:0 ==:. 0 in
  (* ---- exponent difference -> larger exponent e0 + the two right-shift counts ---- *)
  let dx = uresize xe ~width:9 -: uresize ye ~width:9 in
  let dy = uresize ye ~width:9 -: uresize xe ~width:9 in
  (* the larger exponent wins; each operand shifts right by its exponent deficit (0 if it
     is the larger), the borrow bit distinguishing the two cases *)
  let e0 = mux2 (msb dx) (uresize ye ~width:9) (uresize xe ~width:9) in
  let sx = mux2 (msb dy) (zero 8) (select dy ~high:7 ~low:0) in
  let sy = mux2 (msb dx) (zero 8) (select dx ~high:7 ~low:0) in
  (* ---- Stage 0: to two's complement, and shift the smaller operand right ---- The shift
     is arithmetic, of [{sign, mantissa}] truncated to 25 bits: it fills with the
     operand's sign. *)
  let denorm m ~sign ~by = select (log_shift ~f:sra (sign @: m) ~by) ~high:24 ~low:0 in
  (* convert a negative operand to two's complement before the add (not for FLT) *)
  let x0 = mux2 (xs &: ~:(i.u)) (negate xm) xm in
  let y0 = mux2 (ys &: ~:(i.u)) (negate ym) ym in
  let x3 = reg spec (denorm x0 ~sign:xs ~by:sx) -- "x3" in
  let y3 = reg spec (denorm y0 ~sign:ys ~by:sy) -- "y3" in
  (* ---- Stage 1: two's-complement add -> Sum (sign-extended by 2 to hold the carry) ---- *)
  let sum = reg spec ((xs @: xs @: x3) +: (ys @: ys @: y3)) -- "Sum" in
  (* ---- Stage 2: sign-magnitude + guard round, leading-one detect, post-normalize ---- *)
  (* back to sign-magnitude, then +1 rounds via the guard bit *)
  let s = mux2 (msb sum) (negate sum) sum +:. 1 in
  let sc = shift_count s in
  let e1 = e0 -: uresize sc ~width:9 +:. 1 in
  (* post-normalize: shift the leading one up to the hidden-bit position *)
  let t3 = reg spec (log_shift ~f:sll (select s ~high:25 ~low:1) ~by:sc) -- "t3" in
  (* ---- output assembly ---- *)
  (* FLOOR reads the integer straight out of the aligned sum (sign-extended) *)
  let floor_z = sresize (select sum ~high:26 ~low:1) ~width:32 in
  let normal_z = msb sum @: select e1 ~high:7 ~low:0 @: select t3 ~high:23 ~low:1 in
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

(* ── Tests ── The values are checked in test/test_fp_adder.ml against the frozen vectors.
   Here: the timing ([State] walks from 0 to 3 and [stall] drops at 3) and one value, 1.0
   + 1.0. *)

let%expect_test "FPAdder timing — stall envelope (State 0->3) + FAD 1.0 + 1.0 = 2.0" =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let module Waveform = Hardcaml_waveterm.Waveform in
  let module D = Hardcaml_waveterm.Display_rule in
  let sim = Sim.create create in
  let waves, sim = Cyclesim.Waveform.create sim in
  let inp = Cyclesim.inputs sim in
  let outp = Cyclesim.outputs sim in
  let set r v w = r := Bits.of_unsigned_int ~width:w v in
  (* one idle cycle, then FAD with the operands held; [z] is read when [stall] drops, and
     [run] is released on the next cycle, as the core does *)
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

(* Public API and behaviour spec live in [alu.mli].

   Implementation note. This groups the register-op results that RISC5.v computes *inline*
   in its [aluRes] assign (lines 106..125) — MOV, the logic ops, and ADD/SUB — into one
   testable module. They are exactly the ops Wirth left inline, each a native operator (&
   | ^ + -) or a mux. The other register ops are separate peer units: the shifts (1..3) in
   {!Left_shifter}/{!Right_shifter}, and MUL/DIV/FP (10..15) as multi-cycle units. Their
   results are selected alongside this unit's by the result mux at the core (Phase 4), so
   those op slots read as 0 here. *)

open Hardcaml
open Signal

module I = struct
  type 'a t =
    { op : 'a [@bits 4]
    ; u : 'a [@bits 1]
    ; q : 'a [@bits 1]
    ; v : 'a [@bits 1]
    ; imm : 'a [@bits 16]
    ; b : 'a [@bits 32]
    ; c1 : 'a [@bits 32]
    ; h : 'a [@bits 32]
    ; n_in : 'a [@bits 1]
    ; z_in : 'a [@bits 1]
    ; c_in : 'a [@bits 1]
    ; ov_in : 'a [@bits 1]
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t = { res : 'a [@bits 32] } [@@deriving hardcaml]
end

let create (i : _ I.t) : _ O.t =
  let cin =
    (* ADD'/SUB' carry-in (= u & C); prime variants chain the prior carry *)
    uresize (i.u &: i.c_in) ~width:32
  in
  let flags_word =
    (* MOV' flags-read: {N,Z,C,OV, 20'b0, 8'h53} — the 0x53 id byte, AGENT.md §8 *)
    concat_msb [ i.n_in; i.z_in; i.c_in; i.ov_in; zero 20; of_unsigned_int ~width:8 0x53 ]
  in
  let mov =
    (* MOV on u (cf. RISC5.v:111): u=0 -> C1 (covers both q forms — C1 already encodes q);
       u=1 -> q ? imm<<16 : v ? flags_word : H. See the MOV-forms waveform test. *)
    mux2 i.u (mux2 i.q (i.imm @: zero 16) (mux2 i.v flags_word i.h)) i.c1
  in
  let res =
    mux
      i.op
      [ mov (* 0 MOV *)
      ; zero 32 (* 1 LSL — shift peer unit, muxed at core *)
      ; zero 32 (* 2 ASR — shift peer unit, muxed at core *)
      ; zero 32 (* 3 ROR — shift peer unit, muxed at core *)
      ; i.b &: i.c1 (* 4 AND *)
      ; i.b &: ~:(i.c1) (* 5 ANN *)
      ; i.b |: i.c1 (* 6 IOR *)
      ; i.b ^: i.c1 (* 7 XOR *)
      ; i.b +: i.c1 +: cin (* 8 ADD *)
      ; i.b -: i.c1 -: cin (* 9 SUB *)
      ; zero 32 (* 10 MUL — multi-cycle peer, muxed at core *)
      ; zero 32 (* 11 DIV — multi-cycle peer, muxed at core *)
      ; zero 32 (* 12 FAD *)
      ; zero 32 (* 13 FSB *)
      ; zero 32 (* 14 FML *)
      ; zero 32 (* 15 FDV *)
      ]
  in
  { O.res }
;;

(* ── Tests (co-located; AGENT.md §6) ──────────────────────────────────────────
   Correctness: qcheck this unit's ops
   {0 , 4..9}
   — MOV, the logic ops, ADD/SUB — against a plain-OCaml reference (combinational, so no
   oracle). Shifts (1..3) and MUL/DIV/FP (10..15) are peer units tested in their own
   modules and muxed at the core, out of scope here. Behaviour: two curated waveforms
   documenting the subtle bits — the ADD'/SUB' carry-in and the MOV forms. *)

let%expect_test "aluRes = reference, ops {0,4..9} [qcheck, 20k cases]" =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let sim = Sim.create create in
  let inp = Cyclesim.inputs sim in
  let outp = Cyclesim.outputs sim in
  let eval ~op ~u ~q ~v ~imm ~b ~c1 ~h ~n ~z ~c ~ov =
    inp.op := Bits.of_unsigned_int ~width:4 op;
    inp.u := Bits.of_unsigned_int ~width:1 u;
    inp.q := Bits.of_unsigned_int ~width:1 q;
    inp.v := Bits.of_unsigned_int ~width:1 v;
    inp.imm := Bits.of_unsigned_int ~width:16 imm;
    inp.b := Bits.of_unsigned_int ~width:32 b;
    inp.c1 := Bits.of_unsigned_int ~width:32 c1;
    inp.h := Bits.of_unsigned_int ~width:32 h;
    inp.n_in := Bits.of_unsigned_int ~width:1 n;
    inp.z_in := Bits.of_unsigned_int ~width:1 z;
    inp.c_in := Bits.of_unsigned_int ~width:1 c;
    inp.ov_in := Bits.of_unsigned_int ~width:1 ov;
    Cyclesim.cycle sim;
    !(outp.res)
  in
  let mask = 0xFFFF_FFFF in
  let reference ~op ~u ~q ~v ~imm ~b ~c1 ~h ~n ~z ~c ~ov =
    let cin = if u = 1 then c else 0 in
    match op with
    | 0 ->
      (* MOV *)
      if u = 0
      then c1
      else if q = 1
      then (imm lsl 16) land mask
      else if v = 1
      then (n lsl 31) lor (z lsl 30) lor (c lsl 29) lor (ov lsl 28) lor 0x53
      else h
    | 4 -> b land c1 (* AND *)
    | 5 -> b land (lnot c1 land mask) (* ANN *)
    | 6 -> b lor c1 (* IOR *)
    | 7 -> b lxor c1 (* XOR *)
    | 8 -> (b + c1 + cin) land mask (* ADD *)
    | 9 -> (b - c1 - cin) land mask (* SUB *)
    | _ -> 0
  in
  let ops = [| 0; 4; 5; 6; 7; 8; 9 |] in
  QCheck.Test.check_exn
    (QCheck.Test.make
       ~count:20_000
       ~name:"aluRes"
       QCheck.(
         pair
           (quad
              (map (fun k -> ops.(k)) (int_bound 6))
              (int_bound 1)
              (int_bound 1)
              (int_bound 1))
           (pair
              (quad (int_bound 0xFFFF) (int_bound mask) (int_bound mask) (int_bound mask))
              (int_bound 0xF)))
       (fun ((op, u, q, v), ((imm, b, c1, h), f)) ->
         let n = (f lsr 3) land 1
         and z = (f lsr 2) land 1
         and c = (f lsr 1) land 1
         and ov = f land 1 in
         Bits.equal
           (eval ~op ~u ~q ~v ~imm ~b ~c1 ~h ~n ~z ~c ~ov)
           (Bits.of_unsigned_int
              ~width:32
              (reference ~op ~u ~q ~v ~imm ~b ~c1 ~h ~n ~z ~c ~ov))));
  [%expect {| |}]
;;

let%expect_test "ADD/SUB vs ADD'/SUB' — the carry-in [waveform]" =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let module Waveform = Hardcaml_waveterm.For_cyclesim.Waveform in
  let module D = Hardcaml_waveterm.Display_rule in
  let sim = Sim.create create in
  let waves, sim = Waveform.create sim in
  let inp = Cyclesim.inputs sim in
  let set r v w = r := Bits.of_unsigned_int ~width:w v in
  let drive ~op ~u ~c ~b ~c1 =
    set inp.op op 4;
    set inp.u u 1;
    set inp.c_in c 1;
    set inp.b b 32;
    set inp.c1 c1 32;
    Cyclesim.cycle sim
  in
  (* same operands (5,3); op 8=ADD 9=SUB, u=1 = prime variant (folds in carry C) *)
  drive ~op:8 ~u:0 ~c:0 ~b:5 ~c1:3;
  drive ~op:8 ~u:1 ~c:1 ~b:5 ~c1:3;
  drive ~op:9 ~u:0 ~c:0 ~b:5 ~c1:3;
  drive ~op:9 ~u:1 ~c:1 ~b:5 ~c1:3;
  Waveform.print
    ~display_rules:
      D.
        [ port_name_is ~wave_format:Wave_format.Unsigned_int "op"
        ; port_name_is ~wave_format:Wave_format.Bit "u"
        ; port_name_is ~wave_format:Wave_format.Bit "c_in"
        ; port_name_is ~wave_format:Wave_format.Unsigned_int "b"
        ; port_name_is ~wave_format:Wave_format.Unsigned_int "c1"
        ; port_name_is ~wave_format:Wave_format.Unsigned_int "res"
        ]
    ~wave_width:6
    ~display_width:100
    waves;
  [%expect
    {|
    ┌Signals───────────┐┌Waves─────────────────────────────────────────────────────────────────────────┐
    │                  ││────────────────────────────┬───────────────────────────                      │
    │op                ││ 8                          │9                                                │
    │                  ││────────────────────────────┴───────────────────────────                      │
    │u                 ││              ┌─────────────┐             ┌─────────────                      │
    │                  ││──────────────┘             └─────────────┘                                   │
    │c_in              ││              ┌─────────────┐             ┌─────────────                      │
    │                  ││──────────────┘             └─────────────┘                                   │
    │                  ││────────────────────────────────────────────────────────                      │
    │b                 ││ 5                                                                            │
    │                  ││────────────────────────────────────────────────────────                      │
    │                  ││────────────────────────────────────────────────────────                      │
    │c1                ││ 3                                                                            │
    │                  ││────────────────────────────────────────────────────────                      │
    │                  ││──────────────┬─────────────┬─────────────┬─────────────                      │
    │res               ││ 8            │9            │2            │1                                  │
    │                  ││──────────────┴─────────────┴─────────────┴─────────────                      │
    └──────────────────┘└──────────────────────────────────────────────────────────────────────────────┘
    |}]
;;

let%expect_test "MOV forms [waveform]" =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let module Waveform = Hardcaml_waveterm.For_cyclesim.Waveform in
  let module D = Hardcaml_waveterm.Display_rule in
  let sim = Sim.create create in
  let waves, sim = Waveform.create sim in
  let inp = Cyclesim.inputs sim in
  let set r v w = r := Bits.of_unsigned_int ~width:w v in
  let mov
    ?(u = 0)
    ?(q = 0)
    ?(v = 0)
    ?(imm = 0)
    ?(c1 = 0)
    ?(h = 0)
    ?(n = 0)
    ?(z = 0)
    ?(c = 0)
    ?(ov = 0)
    ()
    =
    set inp.op 0 4;
    set inp.u u 1;
    set inp.q q 1;
    set inp.v v 1;
    set inp.imm imm 16;
    set inp.c1 c1 32;
    set inp.h h 32;
    set inp.n_in n 1;
    set inp.z_in z 1;
    set inp.c_in c 1;
    set inp.ov_in ov 1;
    Cyclesim.cycle sim
  in
  (* the four MOV forms in order: C1, imm<<16, H, flags-word *)
  mov ~c1:0xCAFE0000 ();
  mov ~u:1 ~q:1 ~imm:0x1234 ();
  mov ~u:1 ~h:0xABCD ();
  mov ~u:1 ~v:1 ~n:1 ~c:1 ();
  Waveform.print
    ~display_rules:
      D.
        [ port_name_is ~wave_format:Wave_format.Bit "u"
        ; port_name_is ~wave_format:Wave_format.Bit "q"
        ; port_name_is ~wave_format:Wave_format.Bit "v"
        ; port_name_is ~wave_format:Wave_format.Hex "c1"
        ; port_name_is ~wave_format:Wave_format.Hex "imm"
        ; port_name_is ~wave_format:Wave_format.Hex "h"
        ; port_name_is ~wave_format:Wave_format.Hex "res"
        ]
    ~wave_width:8
    ~display_width:110
    waves;
  [%expect
    {|
    ┌Signals───────────┐┌Waves───────────────────────────────────────────────────────────────────────────────────┐
    │u                 ││                  ┌─────────────────────────────────────────────────────                │
    │                  ││──────────────────┘                                                                     │
    │q                 ││                  ┌─────────────────┐                                                   │
    │                  ││──────────────────┘                 └───────────────────────────────────                │
    │v                 ││                                                      ┌─────────────────                │
    │                  ││──────────────────────────────────────────────────────┘                                 │
    │                  ││──────────────────┬─────────────────────────────────────────────────────                │
    │c1                ││ CAFE0000         │00000000                                                             │
    │                  ││──────────────────┴─────────────────────────────────────────────────────                │
    │                  ││──────────────────┬─────────────────┬───────────────────────────────────                │
    │imm               ││ 0000             │1234             │0000                                               │
    │                  ││──────────────────┴─────────────────┴───────────────────────────────────                │
    │                  ││────────────────────────────────────┬─────────────────┬─────────────────                │
    │h                 ││ 00000000                           │0000ABCD         │00000000                         │
    │                  ││────────────────────────────────────┴─────────────────┴─────────────────                │
    │                  ││──────────────────┬─────────────────┬─────────────────┬─────────────────                │
    │res               ││ CAFE0000         │12340000         │0000ABCD         │A0000053                         │
    │                  ││──────────────────┴─────────────────┴─────────────────┴─────────────────                │
    └──────────────────┘└────────────────────────────────────────────────────────────────────────────────────────┘
    |}]
;;

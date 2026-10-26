(* The inline part of RISC5.v's [aluRes] (lines 106..125), as a unit; the contract is in
   [alu.mli]. *)

open Hardcaml
open Signal

module I = struct
  type 'a t =
    { p : 'a [@bits 1]
    ; op : 'a [@bits 4]
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
  type 'a t =
    { res : 'a [@bits 32]
    ; c : 'a [@bits 1]
    ; ov : 'a [@bits 1]
    }
  [@@deriving hardcaml]
end

let create (i : _ I.t) : _ O.t =
  let cin = i.u &: i.c_in in
  let flags_word =
    (* the flags in the top nibble over the identification byte 0x53, as RISC5.v has it
       (the C emulator returns 0xD0 there) *)
    concat_msb [ i.n_in; i.z_in; i.c_in; i.ov_in; zero 20; of_unsigned_int ~width:8 0x53 ]
  in
  let mov =
    (* MOV has four forms. With u = 0 it moves operand 2. With u = 1: q = 1 gives imm <<
       16; q = 0 gives the flags word (v = 1) or H (v = 0). *)
    mux2 i.u (mux2 i.q (i.imm @: zero 16) (mux2 i.v flags_word i.h)) i.c1
  in
  (* ADD and SUB, each computed one bit wider, twice: zero-extended, the top bit is the
     carry or borrow; sign-extended, the top two bits disagree exactly on overflow. The
     carry-in u & C makes ADD' and SUB'. *)
  let cin33 = uresize cin ~width:33 in
  let addsub f =
    let u = f (f (ue i.b) (ue i.c1)) cin33 in
    let s = f (f (se i.b) (se i.c1)) cin33 in
    let result = lsbs u in
    result, msb u, msb s <>: msb result
  in
  let add_res, add_c, add_ov = addsub ( +: ) in
  let sub_res, sub_c, sub_ov = addsub ( -: ) in
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
      ; add_res (* 8 ADD *)
      ; sub_res (* 9 SUB *)
      ; zero 32 (* 10 MUL — multi-cycle peer, muxed at core *)
      ; zero 32 (* 11 DIV — multi-cycle peer, muxed at core *)
      ; zero 32 (* 12 FAD *)
      ; zero 32 (* 13 FSB *)
      ; zero 32 (* 14 FML *)
      ; zero 32 (* 15 FDV *)
      ]
  in
  (* Only a register ADD or SUB changes C and OV. The [~p] matters: a branch or memory
     instruction whose [op] field happens to be 8 or 9 must leave the flags alone. Without
     it such a branch recomputed a carry, and a stalled conditional branch then evaluated
     the corrupted flag — a bug that showed only while booting. The result mux needs no
     such guard: the core never selects it for those instructions. *)
  let is_add = ~:(i.p) &: (i.op ==:. 8) in
  let is_sub = ~:(i.p) &: (i.op ==:. 9) in
  let c = mux2 is_add add_c (mux2 is_sub sub_c i.c_in) in
  let ov = mux2 is_add add_ov (mux2 is_sub sub_ov i.ov_in) in
  { O.res; c; ov }
;;

(* ── Tests ── A property test of operations 0 and 4..9, with C and OV, against a plain-
   OCaml reference; and waveforms of the subtle parts: the carry-in, the MOV forms, carry
   against overflow. *)

let set r v w = r := Bits.of_unsigned_int ~width:w v

let%expect_test "aluRes = reference, ops {0,4..9} [qcheck, 20k cases]" =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let sim = Sim.create create in
  let inp = Cyclesim.inputs sim in
  let outp = Cyclesim.outputs sim in
  let eval ~p ~op ~u ~q ~v ~imm ~b ~c1 ~h ~n ~z ~c ~ov =
    inp.p := Bits.of_unsigned_int ~width:1 p;
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
    !(outp.res), !(outp.c), !(outp.ov)
  in
  let mask = 0xFFFF_FFFF in
  let bit31 x = (x lsr 31) land 1 in
  let reference ~p ~op ~u ~q ~v ~imm ~b ~c1 ~h ~n ~z ~c ~ov =
    let cin = if u = 1 then c else 0 in
    let res =
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
    (* C and OV: ADD's carry, SUB's borrow and the signed overflow, for a register ADD or
       SUB only; anything else passes them through *)
    let cf, vf =
      match op with
      | 8 when p = 0 ->
        let sa = bit31 res
        and sb = bit31 b
        and sc = bit31 c1 in
        ((b + c1 + cin) lsr 32) land 1, if sb = sc && sa <> sb then 1 else 0
      | 9 when p = 0 ->
        let sa = bit31 res
        and sb = bit31 b
        and sc = bit31 c1 in
        (if b < c1 + cin then 1 else 0), if sb <> sc && sa <> sb then 1 else 0
      | _ -> c, ov
    in
    res, cf, vf
  in
  let ops = [| 0; 4; 5; 6; 7; 8; 9 |] in
  (* [p] is generated too, not pinned to 0: the flag bug described above escaped this test
     while it drove only register instructions. Only the C/OV check can tell the two
     values of [p] apart. *)
  Test_gen.check_exn
    (QCheck.Test.make
       ~count:20_000
       ~name:"aluRes + C/OV honour ~p"
       QCheck.(
         pair
           (pair
              (quad
                 (map (fun k -> ops.(k)) (int_bound 6))
                 (int_bound 1)
                 (int_bound 1)
                 (int_bound 1))
              (int_bound 1))
           (pair
              (quad (int_bound 0xFFFF) Test_gen.word32 Test_gen.word32 Test_gen.word32)
              (int_bound 0xF)))
       (fun (((op, u, q, v), p), ((imm, b, c1, h), f)) ->
         let n = (f lsr 3) land 1
         and z = (f lsr 2) land 1
         and c = (f lsr 1) land 1
         and ov = f land 1 in
         let er, ec, eov = eval ~p ~op ~u ~q ~v ~imm ~b ~c1 ~h ~n ~z ~c ~ov in
         let rr, rc, rov = reference ~p ~op ~u ~q ~v ~imm ~b ~c1 ~h ~n ~z ~c ~ov in
         Bits.equal er (Bits.of_unsigned_int ~width:32 rr)
         && Bits.equal ec (Bits.of_unsigned_int ~width:1 rc)
         && Bits.equal eov (Bits.of_unsigned_int ~width:1 rov)));
  [%expect {| |}]
;;

let%expect_test "ADD/SUB flags — carry-out vs overflow [waveform]" =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let module Waveform = Hardcaml_waveterm.Waveform in
  let module D = Hardcaml_waveterm.Display_rule in
  let sim = Sim.create create in
  let waves, sim = Cyclesim.Waveform.create sim in
  let inp = Cyclesim.inputs sim in
  let drive ~op ~b ~c1 =
    set inp.op op 4;
    set inp.b b 32;
    set inp.c1 c1 32;
    Cyclesim.cycle sim
  in
  (* op 8=ADD 9=SUB; C = carry-out (ADD) / borrow (SUB), OV = signed overflow *)
  drive ~op:8 ~b:0xFFFFFFFF ~c1:0x1;
  drive ~op:8 ~b:0x7FFFFFFF ~c1:0x1;
  drive ~op:9 ~b:0x1 ~c1:0x2;
  drive ~op:9 ~b:0x80000000 ~c1:0x1;
  Waveform.print
    ~display_rules:
      D.
        [ port_name_is ~wave_format:Wave_format.Unsigned_int "op"
        ; port_name_is ~wave_format:Wave_format.Hex "b"
        ; port_name_is ~wave_format:Wave_format.Hex "c1"
        ; port_name_is ~wave_format:Wave_format.Hex "res"
        ; port_name_is ~wave_format:Wave_format.Bit "c"
        ; port_name_is ~wave_format:Wave_format.Bit "ov"
        ]
    ~wave_width:4
    ~display_width:58
    waves;
  [%expect
    {|
    ┌Signals─────┐┌Waves─────────────────────────────────────┐
    │            ││────────────────────┬───────────────────  │
    │op          ││ 8                  │9                    │
    │            ││────────────────────┴───────────────────  │
    │            ││──────────┬─────────┬─────────┬─────────  │
    │b           ││ FFFFFFFF │7FFFFFFF │00000001 │80000000   │
    │            ││──────────┴─────────┴─────────┴─────────  │
    │            ││────────────────────┬─────────┬─────────  │
    │c1          ││ 00000001           │00000002 │00000001   │
    │            ││────────────────────┴─────────┴─────────  │
    │            ││──────────┬─────────┬─────────┬─────────  │
    │res         ││ 00000000 │80000000 │FFFFFFFF │7FFFFFFF   │
    │            ││──────────┴─────────┴─────────┴─────────  │
    │c           ││──────────┐         ┌─────────┐           │
    │            ││          └─────────┘         └─────────  │
    │ov          ││          ┌─────────┐         ┌─────────  │
    │            ││──────────┘         └─────────┘           │
    └────────────┘└──────────────────────────────────────────┘
    |}]
;;

let%expect_test "ADD/SUB vs ADD'/SUB' — the carry-in [waveform]" =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let module Waveform = Hardcaml_waveterm.Waveform in
  let module D = Hardcaml_waveterm.Display_rule in
  let sim = Sim.create create in
  let waves, sim = Cyclesim.Waveform.create sim in
  let inp = Cyclesim.inputs sim in
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
    ~wave_width:4
    ~display_width:58
    waves;
  [%expect
    {|
    ┌Signals─────┐┌Waves─────────────────────────────────────┐
    │            ││────────────────────┬───────────────────  │
    │op          ││ 8                  │9                    │
    │            ││────────────────────┴───────────────────  │
    │u           ││          ┌─────────┐         ┌─────────  │
    │            ││──────────┘         └─────────┘           │
    │c_in        ││          ┌─────────┐         ┌─────────  │
    │            ││──────────┘         └─────────┘           │
    │            ││────────────────────────────────────────  │
    │b           ││ 5                                        │
    │            ││────────────────────────────────────────  │
    │            ││────────────────────────────────────────  │
    │c1          ││ 3                                        │
    │            ││────────────────────────────────────────  │
    │            ││──────────┬─────────┬─────────┬─────────  │
    │res         ││ 8        │9        │2        │1          │
    │            ││──────────┴─────────┴─────────┴─────────  │
    └────────────┘└──────────────────────────────────────────┘
    |}]
;;

let%expect_test "MOV forms [waveform]" =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let module Waveform = Hardcaml_waveterm.Waveform in
  let module D = Hardcaml_waveterm.Display_rule in
  let sim = Sim.create create in
  let waves, sim = Cyclesim.Waveform.create sim in
  let inp = Cyclesim.inputs sim in
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
    ~wave_width:4
    ~display_width:58
    waves;
  [%expect
    {|
    ┌Signals─────┐┌Waves─────────────────────────────────────┐
    │u           ││          ┌─────────────────────────────  │
    │            ││──────────┘                               │
    │q           ││          ┌─────────┐                     │
    │            ││──────────┘         └───────────────────  │
    │v           ││                              ┌─────────  │
    │            ││──────────────────────────────┘           │
    │            ││──────────┬─────────────────────────────  │
    │c1          ││ CAFE0000 │00000000                       │
    │            ││──────────┴─────────────────────────────  │
    │            ││──────────┬─────────┬───────────────────  │
    │imm         ││ 0000     │1234     │0000                 │
    │            ││──────────┴─────────┴───────────────────  │
    │            ││────────────────────┬─────────┬─────────  │
    │h           ││ 00000000           │0000ABCD │00000000   │
    │            ││────────────────────┴─────────┴─────────  │
    │            ││──────────┬─────────┬─────────┬─────────  │
    │res         ││ CAFE0000 │12340000 │0000ABCD │A0000053   │
    │            ││──────────┴─────────┴─────────┴─────────  │
    └────────────┘└──────────────────────────────────────────┘
    |}]
;;

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
    (* MOV' flags-read: the four flags in the top nibble over the 0x53 id byte (AGENT.md
       §8 — the hardware id byte, not the C reference's 0xD0) *)
    concat_msb [ i.n_in; i.z_in; i.c_in; i.ov_in; zero 20; of_unsigned_int ~width:8 0x53 ]
  in
  let mov =
    (* MOV's four forms as a mux2 tree on u/q/v; see the MOV-forms waveform. Read each
       mux2 as a hardware if: u ? (q ? imm<<16 : v ? flags_word : H) : C1. So u=0 -> C1
       (normal move; C1 already encodes the q imm/R.c choice); u=1,q=1 -> imm<<16;
       u=1,q=0,v=1 -> flags word (N,Z,C,OV); u=1,q=0,v=0 -> H (MUL high word / DIV
       remainder). *)
    mux2 i.u (mux2 i.q (i.imm @: zero 16) (mux2 i.v flags_word i.h)) i.c1
  in
  (* ADD and SUB, each one bit wider, via [addsub op] (op is +: or -:). The unsigned widen
     gives the result (low 32) and carry/borrow (top bit); the signed widen gives overflow
     (its top two bits disagree — the exact signed sum needed a 33rd bit). Carry-in cin =
     u & C feeds the ADD'/SUB' variants. *)
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
  (* C/OV come from the active arithmetic op; every other op leaves the current C/OV
     unchanged. N/Z are not here — they derive from the final write value (regmux), at the
     core. *)
  (* ADD/SUB set C/OV; every other instruction holds them. The [~p] qualifier is
     load-bearing and matches [RISC5.v]'s [ADD = ~p & (op==8)] / [SUB = ~p & (op==9)]: a
     branch or memory instruction ([p=1]) whose [op] field happens to be 8/9 must NOT
     touch the flags. Without it, e.g. [BLR] [0xDA08281C] (op-field 8) spuriously
     recomputes a carry and clobbers C — latent until a *stalled* conditional branch
     re-evaluates the corrupted flag on its stall cycle (the phase-6b boot trap). The
     result mux above stays op-only, like [aluRes]: its value for a branch is simply never
     selected by the core's [regmux]. *)
  let is_add = ~:(i.p) &: (i.op ==: of_unsigned_int ~width:4 8) in
  let is_sub = ~:(i.p) &: (i.op ==: of_unsigned_int ~width:4 9) in
  let c = mux2 is_add add_c (mux2 is_sub sub_c i.c_in) in
  let ov = mux2 is_add add_ov (mux2 is_sub sub_ov i.ov_in) in
  { O.res; c; ov }
;;

(* ── Tests (co-located; AGENT.md §6) ──────────────────────────────────────────
   Correctness: qcheck this unit's ops 0 and 4..9 — MOV, logic, ADD/SUB plus the C/OV
   flags — against a plain-OCaml reference (combinational, so no oracle). Shifts (1..3)
   and MUL/DIV/FP (10..15) are peer units tested in their own modules and muxed at the
   core, out of scope here. Behaviour: curated waveforms for the subtle bits — the
   ADD'/SUB' carry-in, the MOV forms, and carry-vs-overflow. *)

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
    (* C/OV: ADD carry-out / SUB borrow + signed overflow — but ONLY for register ADD/SUB
       ([p=0]). Any other instruction (including a [p=1] branch/memory op whose [op] field
       is 8/9) passes (c, ov) through, mirroring [RISC5.v]'s [ADD = ~p & (op==8)]. *)
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
  (* [p] is generated alongside the op fields, not pinned to 0: with [p=1] (a
     branch/memory instruction) ADD/SUB must NOT touch C/OV even when [op] is 8/9 — the
     flag-leak bug that escaped this test while it only ever drove register ops. The
     result mux is op-only (p-independent), so only the C/OV check distinguishes the two
     values of [p]. *)
  QCheck.Test.check_exn
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
              (quad (int_bound 0xFFFF) (int_bound mask) (int_bound mask) (int_bound mask))
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
  let module Waveform = Hardcaml_waveterm.For_cyclesim.Waveform in
  let module D = Hardcaml_waveterm.Display_rule in
  let sim = Sim.create create in
  let waves, sim = Waveform.create sim in
  let inp = Cyclesim.inputs sim in
  let set r v w = r := Bits.of_unsigned_int ~width:w v in
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

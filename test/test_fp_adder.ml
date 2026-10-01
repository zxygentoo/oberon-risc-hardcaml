(* The FP adder's values, over the domain the compiler emits.

   The reference is the frozen fp_vectors.txt, generated from the C emulator, which
   [Emu.Fp] reproduces exactly. Each line [A x y u v result] is one FAD, FSB, FLT or FLOOR
   case. What the compiler can emit:
   - FAD and FSB (u = v = 0): any operands;
   - FLT (u = 1) and FLOOR (v = 1): the second operand is always 0x4B000000 (2^23), the
     constant that makes the alignment shift round to an integer (ORG.Mod, Float and
     Floor).

   FPAdder.v and the emulator differ only outside that domain — FLT or FLOOR with another
   second operand, and the impossible u = v = 1 — in how the alignment shift fills. The
   port follows the RTL there (the co-simulation shows it bit-exact), so those vectors are
   skipped. The reachable ones are replayed, and the reachable FLT and FLOOR domain is
   fuzzed against [Emu.Fp], the frozen file holding only a couple of dozen of each. *)

open Hardcaml
module Fp = Risc5.Fp_adder

(* RH: the compiler's fixed FLT/FLOOR second operand (ORG.Mod Float/Floor) *)
let magic = 0x4B00_0000

(* a frozen A-vector is compiler-reachable iff FAD/FSB (u=v=0, any operands) or exactly
   one of FLT/FLOOR with the magic second operand. ORG.Mod never emits y<>magic for
   FLT/FLOOR, nor u=v=1. *)
let reachable ~u ~v ~y = (u = 0 && v = 0) || (u + v = 1 && y = magic)

(* the FLT/FLOOR edge inputs checked deterministically before the random fuzz: small ints,
   mantissa/exponent boundaries, and a few known float bit-patterns *)
let edges =
  [ 0
  ; 1
  ; 2
  ; 5
  ; 0x100
  ; 0x7F_FFFF
  ; 0x80_0000
  ; 0xFF_FFFF
  ; 0x7FFF_FFFF
  ; 0x8000_0000
  ; 0xFFFF_FFFF
  ; 0x3F80_0000
  ; 0x4049_0FDB
  ; 0xC000_0000
  ; magic
  ; 0x7F80_0000
  ]
;;

(* build the [run ~u ~v ~x ~y] driver over a fresh FPAdder sim (the run->drain->read
   protocol from Fp_replay) *)
let make_run () =
  let module Sim = Cyclesim.With_interface (Fp.I) (Fp.O) in
  let sim = Sim.create Fp.create in
  let inp = (Cyclesim.inputs sim : _ Fp.I.t)
  and outp = (Cyclesim.outputs sim : _ Fp.O.t) in
  fun ~u ~v ~x ~y ->
    Fp_replay.set inp.u u;
    Fp_replay.set inp.v v;
    Fp_replay.set inp.x x;
    Fp_replay.set inp.y y;
    Fp_replay.drive sim ~run:inp.run ~stall:outp.stall ~z:outp.z
;;

(* replay the frozen A-vectors over the compiler-reachable domain only. Prints a summary;
   returns the mismatch count. *)
let replay_reachable run =
  let fails = ref 0
  and replayed = ref 0
  and skipped = ref 0
  and shown = ref 0 in
  Fp_replay.iter_vectors ~tag:"A" ~f:(function
    | [ x; y; u; v; r ] ->
      let x = Fp_replay.hex x
      and y = Fp_replay.hex y
      and u = Fp_replay.hex u
      and v = Fp_replay.hex v
      and want = Fp_replay.hex r in
      if not (reachable ~u ~v ~y)
      then incr skipped
      else (
        incr replayed;
        let got = run ~u ~v ~x ~y in
        if got <> want
        then (
          incr fails;
          if !shown < 10
          then (
            incr shown;
            Printf.printf
              "  vec FAIL x=%08X y=%08X u=%d v=%d: got %08X want %08X\n"
              x
              y
              u
              v
              got
              want)))
    | fields -> Fp_replay.malformed ~tag:"A" fields);
  if !replayed = 0 then failwith "fp-adder: no reachable A-vectors replayed";
  Printf.printf
    "fp-adder frozen: %d/%d reachable A-vectors pass (%d unreachable skipped: FLT/FLOOR \
     y<>magic + u=v=1)\n"
    (!replayed - !fails)
    !replayed
    !skipped;
  !fails
;;

(* The reachable FLT and FLOOR domain against [Emu.Fp]: the edge list first, then random
   integers, each checked as FLT and as FLOOR. Returns the edge mismatches; the random
   pass raises on a failure. *)
let fuzz_conversions run =
  let conv_fails = ref 0
  and conv_n = ref 0 in
  let check_conv ~u ~v x =
    incr conv_n;
    let got = run ~u ~v ~x ~y:magic in
    let want = Emu.Fp.fp_add x magic (u = 1) (v = 1) in
    if got <> want
    then (
      incr conv_fails;
      if !conv_fails <= 10
      then
        Printf.printf "  edge FAIL u=%d v=%d x=%08X: got %08X want %08X\n" u v x got want)
  in
  List.iter
    (fun x ->
      check_conv ~u:1 ~v:0 x;
      check_conv ~u:0 ~v:1 x)
    edges;
  Risc5.Test_gen.check_exn
    (QCheck.Test.make
       ~count:5000
       ~name:"fp-adder FLT/FLOOR fuzz"
       Risc5.Test_gen.word32
       (fun x ->
          run ~u:1 ~v:0 ~x ~y:magic = Emu.Fp.fp_add x magic true false
          && run ~u:0 ~v:1 ~x ~y:magic = Emu.Fp.fp_add x magic false true));
  Printf.printf
    "fp-adder fuzz: %d edge + 5000 QCheck FLT/FLOOR cases vs Emu.Fp, %d edge fail\n"
    !conv_n
    !conv_fails;
  !conv_fails
;;

let () =
  let run = make_run () in
  let frozen_fails = replay_reachable run in
  let edge_fails = fuzz_conversions run in
  if frozen_fails > 0 || edge_fails > 0 then exit 1
;;

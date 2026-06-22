(* Phase 3b — FPAdder value-correctness, over the domain the compiler actually emits.

   The §5/§6 oracle is the frozen fp_vectors.txt (C-generated; Oracle.Fp is bit-identical
   to it). Each [A x y u v result] line is one FAD/FSB/FLT/FLOOR case. We verify the
   Hardcaml Fp_adder over the COMPILER-REACHABLE domain:
   - FAD/FSB (u=0, v=0): any operands.
   - FLT (u=1) / FLOOR (v=1): the compiler (ORG.Mod, Float/Floor) fixes the second operand
     to RH = 0x4B000000 (2^23, the round-to-integer magic constant; exponent 150).

   FPAdder.v and the oracle diverge ONLY outside that domain — FLT/FLOOR paired with any
   other second operand, plus the impossible u=v=1 op — via the denormalize sign-fill.
   Those inputs are unreachable, confirmed three ways: ORG.Mod source; a bucketed replay
   (every reachable bucket 100% pass); and a Verilator co-sim of FPAdder.v (the Hardcaml
   port is bit-exact to the RTL, agreeing with it AND disagreeing with the oracle on the
   junk). So we replay the reachable frozen vectors, steer around the unreachable forms,
   and additionally fuzz the reachable FLT/FLOOR domain (random integer/float x, y=magic)
   against Oracle.Fp for depth the ~24-each frozen sample lacks. See the
   [[fp-flt-floor-magic-operand]] memory. *)

open Hardcaml
module Fp = Risc5.Fp_adder

(* cwd at runtime is _build/default/test/; the vendored vectors are a dune dep (see dune) *)
let vectors_path = "../vendor/oberon-risc-emu-ocaml/test/data/fp_vectors.txt"

(* RH: the compiler's fixed FLT/FLOOR second operand (ORG.Mod Float/Floor) *)
let magic = 0x4B00_0000

(* one FAD/FLT/FLOOR through the sim: hold inputs, run, drain until stall drops, read z,
   then release run for a cycle to clear State back to 0 (the same pattern as MUL/DIV). *)
let run_fp_add sim ~u ~v ~x ~y =
  let inp = (Cyclesim.inputs sim : _ Fp.I.t) in
  let outp = (Cyclesim.outputs sim : _ Fp.O.t) in
  let set r value w = r := Bits.of_unsigned_int ~width:w value in
  set inp.u u 1;
  set inp.v v 1;
  set inp.x x 32;
  set inp.y y 32;
  set inp.run 1 1;
  Cyclesim.cycle sim;
  let safety = ref 0 in
  while Bits.to_int_trunc !(outp.stall) = 1 do
    Cyclesim.cycle sim;
    incr safety;
    if !safety > 16 then failwith "fp_adder did not terminate"
  done;
  let z = Bits.to_unsigned_int !(outp.z) in
  set inp.run 0 1;
  Cyclesim.cycle sim;
  z
;;

(* parse the [A] lines into (x, y, u, v, expected_z); all fields hex, no 0x prefix *)
let load_add_vectors path =
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
      let acc = ref [] in
      (try
         while true do
           match
             String.split_on_char ' ' (input_line ic) |> List.filter (fun s -> s <> "")
           with
           | [ "A"; x; y; u; v; r ] ->
             let h s = int_of_string ("0x" ^ s) in
             acc := (h x, h y, h u, h v, h r) :: !acc
           | _ -> ()
         done
       with
       | End_of_file -> ());
      List.rev !acc)
;;

(* a frozen A-vector is compiler-reachable iff FAD/FSB (u=v=0, any operands) or exactly
   one of FLT/FLOOR with the magic second operand. ORG.Mod never emits y<>magic for
   FLT/FLOOR, nor u=v=1. *)
let reachable ~u ~v ~y = (u = 0 && v = 0) || (u + v = 1 && y = magic)

let () =
  let vectors = load_add_vectors vectors_path in
  let module Sim = Cyclesim.With_interface (Fp.I) (Fp.O) in
  let sim = Sim.create Fp.create in
  (* 1. Frozen vectors, reachable domain only. *)
  let fails = ref 0 in
  let replayed = ref 0 in
  let skipped = ref 0 in
  let shown = ref 0 in
  List.iter
    (fun (x, y, u, v, want) ->
      if not (reachable ~u ~v ~y)
      then incr skipped
      else (
        incr replayed;
        let got = run_fp_add sim ~u ~v ~x ~y in
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
              want))))
    vectors;
  Printf.printf
    "fp-adder frozen: %d/%d reachable A-vectors pass (%d unreachable skipped: FLT/FLOOR \
     y<>magic + u=v=1)\n"
    (!replayed - !fails)
    !replayed
    !skipped;
  (* 2. Fuzz the reachable FLT/FLOOR domain (y=magic) against Oracle.Fp directly — the
     frozen set samples only ~24 x each, and FLT's real domain is 32-bit integers. Fixed
     seed. *)
  let rng = Random.State.make [| 0x3b_07 |] in
  let rand32 () =
    (Random.State.int rng 0x10000 lsl 16) lor Random.State.int rng 0x10000
  in
  let conv_fails = ref 0 in
  let conv_n = ref 0 in
  let check_conv ~u ~v x =
    incr conv_n;
    let got = run_fp_add sim ~u ~v ~x ~y:magic in
    let want = Oracle.Fp.fp_add x magic (u = 1) (v = 1) in
    if got <> want
    then (
      incr conv_fails;
      if !conv_fails <= 10
      then
        Printf.printf "  fuzz FAIL u=%d v=%d x=%08X: got %08X want %08X\n" u v x got want)
  in
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
  in
  List.iter
    (fun x ->
      check_conv ~u:1 ~v:0 x;
      check_conv ~u:0 ~v:1 x)
    edges;
  for _ = 1 to 5000 do
    let x = rand32 () in
    check_conv ~u:1 ~v:0 x;
    check_conv ~u:0 ~v:1 x
  done;
  Printf.printf
    "fp-adder fuzz: %d reachable FLT/FLOOR cases vs Oracle.Fp, %d fail\n"
    !conv_n
    !conv_fails;
  if !fails > 0 || !conv_fails > 0 then exit 1
;;

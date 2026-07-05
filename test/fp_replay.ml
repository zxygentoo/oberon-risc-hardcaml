(* Shared harness for the FP units' value-correctness replays (the three
   test_fp_adder/_multiplier/_divider executables). The sim-drive protocol, the
   frozen-vector loader and the fuzz RNG live here once; each test supplies its unit (via
   a [run] closure that hides the interface differences — the adder carries u/v, mul/div
   don't), its [fp_vectors] line tag and its [Emu.Fp] function.

   This is the value-correctness (behavioural) layer that runs under `dune runtest`,
   distinct from the opt-in Verilator fidelity co-sim in test/cosim/ (AGENT.md §6). The
   helper is oracle-agnostic — the oracle function is passed in — so it stays a thin
   Hardcaml dependency. *)

open Hardcaml

(* cwd at runtime is _build/default/test/; the vendored vectors are a dune dep (see dune) *)
let vectors_path = "../vendor/oberon-risc-emu-ocaml/test/data/fp_vectors.txt"
let hex s = int_of_string ("0x" ^ s)

(* set an input ref to [v] using the port's own declared width (1 for run, 32 for
   x/y/...). *)
let set r v = r := Bits.of_unsigned_int ~width:(Bits.width !r) v

(* the shared run -> drain on stall -> read z -> release protocol; [run]/[stall]/[z] are
   the unit's ports (the same [Bits.t ref] type across all FP units) and [sim] is used
   polymorphically. The caller has already set the data inputs (x/y and any u/v) for this
   op. *)
let drive sim ~run ~stall ~z =
  set run 1;
  Cyclesim.cycle sim;
  let safety = ref 0 in
  while Bits.to_int_trunc !stall = 1 do
    Cyclesim.cycle sim;
    incr safety;
    if !safety > 40 then failwith "FP unit did not terminate"
  done;
  let result = Bits.to_unsigned_int !z in
  set run 0;
  Cyclesim.cycle sim;
  result
;;

(* QCheck's [int32] gives full 32-bit coverage with edge cases (0, min, max) and
   shrinking; reinterpret it as an unsigned 32-bit word for the units/oracle *)
let u32 (x : int32) = Int32.to_int x land 0xFFFF_FFFF

(* apply [f] to the space-separated fields *after the tag* of every [tag]-line in the
   vectors *)
let iter_vectors ~tag ~f =
  let ic = open_in vectors_path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
      try
        while true do
          match
            String.split_on_char ' ' (input_line ic) |> List.filter (fun s -> s <> "")
          with
          | t :: rest when String.equal t tag -> f rest
          | _ -> ()
        done
      with
      | End_of_file -> ())
;;

(* replay every frozen [tag]-vector ([tag x y result]) against the port's [run ~x ~y],
   comparing to the result column. Prints a summary; returns the mismatch count. *)
let replay_simple ~name ~tag ~run =
  let fails = ref 0
  and n = ref 0
  and shown = ref 0 in
  iter_vectors ~tag ~f:(function
    | [ x; y; r ] ->
      incr n;
      let x = hex x
      and y = hex y
      and want = hex r in
      let got = run ~x ~y in
      if got <> want
      then (
        incr fails;
        if !shown < 10
        then (
          incr shown;
          Printf.printf "  vec FAIL x=%08X y=%08X: got %08X want %08X\n" x y got want))
    | _ -> ());
  Printf.printf "%s frozen: %d/%d %s-vectors pass\n" name (!n - !fails) !n tag;
  !fails
;;

(* fuzz the full operand domain against [oracle] (QCheck int32 — boundary coverage +
   shrinking); raises (test fails) on any mismatch *)
let fuzz_xy ~name ~run ~oracle =
  QCheck.Test.check_exn
    (QCheck.Test.make
       ~count:20_000
       ~name:(name ^ " fuzz")
       (QCheck.set_print
          (fun (x, y) -> Printf.sprintf "x=%08lx y=%08lx" x y)
          (QCheck.pair QCheck.int32 QCheck.int32))
       (fun (x, y) ->
         let x = u32 x
         and y = u32 y in
         run ~x ~y = oracle x y));
  Printf.printf "%s fuzz: 20000 QCheck cases vs Emu.Fp, ok\n" name
;;

(* No-steering value test for a unit with no compiler-unreachable / divergent domain (FML,
   FDV): replay the frozen vectors, then fuzz against [oracle]. (The adder can't use this
   — its FLT/FLOOR domain needs steering — so test_fp_adder drives the helpers directly.) *)
let simple_value_test ~name ~tag ~run ~oracle =
  let fails = replay_simple ~name ~tag ~run in
  fuzz_xy ~name ~run ~oracle;
  if fails > 0 then exit 1
;;

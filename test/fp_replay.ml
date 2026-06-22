(* Shared harness for the FP units' value-correctness replays (the three
   test_fp_adder/_multiplier/_divider executables). The sim-drive protocol, the
   frozen-vector loader and the fuzz RNG live here once; each test supplies its unit (via
   a [run] closure that hides the interface differences — the adder carries u/v, mul/div
   don't), its [fp_vectors] line tag and its [Oracle.Fp] function.

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

(* a deterministic 32-bit fuzz draw from [rng] *)
let rand32 rng = (Random.State.int rng 0x10000 lsl 16) lor Random.State.int rng 0x10000

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

(* No-steering value test, for a unit with no compiler-unreachable / divergent domain
   (FML, FDV): replay every [tag]-vector ([tag x y result]) and a 20k random fuzz pass
   against the port's [run ~x ~y] — the frozen vectors compared to their result column,
   the fuzz to [oracle]. Prints a summary and exits 1 on any mismatch. (The adder cannot
   use this: its FLT/FLOOR domain needs steering, so test_fp_adder drives the shared
   helpers directly.) *)
let simple_value_test ~name ~tag ~run ~oracle =
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
  let rng = Random.State.make [| 0x5d_21 |] in
  let fuzz_fails = ref 0
  and fuzz_n = ref 0
  and fshown = ref 0 in
  for _ = 1 to 20000 do
    let x = rand32 rng
    and y = rand32 rng in
    incr fuzz_n;
    let got = run ~x ~y in
    let want = oracle x y in
    if got <> want
    then (
      incr fuzz_fails;
      if !fshown < 10
      then (
        incr fshown;
        Printf.printf "  fuzz FAIL x=%08X y=%08X: got %08X want %08X\n" x y got want))
  done;
  Printf.printf "%s fuzz: %d cases vs Oracle.Fp, %d fail\n" name !fuzz_n !fuzz_fails;
  if !fails > 0 || !fuzz_fails > 0 then exit 1
;;

(* Shared by the three FP value tests: the protocol for driving a unit, the loader for the
   frozen vectors, and the fuzz. Each test supplies its unit (as a [run] closure, which
   hides that the adder has u and v and the others do not), its tag in the vector file and
   its function in [Emu.Fp].

   These tests check values against the emulator and run in [dune runtest]. Fidelity to
   the RTL is the co-simulation's job. *)

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

(* a vector line that does not have the fields its tag promises is an error, not a line to
   skip: skipped lines are how a replay ends up passing on nothing *)
let malformed ~tag fields =
  failwith
    (Printf.sprintf
       "%s: malformed %s-vector: %s"
       vectors_path
       tag
       (String.concat " " fields))
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
    | fields -> malformed ~tag fields);
  if !n = 0 then failwith (Printf.sprintf "%s: no %s-vectors in %s" name tag vectors_path);
  Printf.printf "%s frozen: %d/%d %s-vectors pass\n" name (!n - !fails) !n tag;
  !fails
;;

(* fuzz the full operand domain against [oracle] — uniform bit patterns mixed with the
   exponent/mantissa edges ({!Risc5.Test_gen.fp32}); raises (test fails) on any mismatch *)
let fuzz_xy ~name ~run ~oracle =
  Risc5.Test_gen.check_exn
    (QCheck.Test.make
       ~count:20_000
       ~name:(name ^ " fuzz")
       (QCheck.pair Risc5.Test_gen.fp32 Risc5.Test_gen.fp32)
       (fun (x, y) -> run ~x ~y = oracle x y));
  Printf.printf "%s fuzz: 20000 QCheck cases vs Emu.Fp, ok\n" name
;;

(* For a unit where the emulator and the RTL agree everywhere (FML, FDV): replay the
   frozen vectors, then fuzz. The adder cannot use this; see test_fp_adder. *)
let simple_value_test ~name ~tag ~run ~oracle =
  let fails = replay_simple ~name ~tag ~run in
  fuzz_xy ~name ~run ~oracle;
  if fails > 0 then exit 1
;;

(* Dump the Hardcaml Fp_adder's output for a stimulus set, as lines "x y u v z" (x/y/z
   hex, u/v decimal), so the Verilator co-sim of FPAdder.v (test/cosim/fp_adder.cpp) can
   assert RTL z == port z over the whole set. This is a port-vs-RTL FIDELITY check, so the
   stimuli are (a) the frozen fp_vectors A-lines reused as corner stimuli (the expected-z
   column is ignored — we compare against the RTL, not the software oracle) and (b) a
   deterministic random fuzz pass for breadth. See test/cosim/README.md.

   Usage: dump_fp_adder <path to fp_vectors.txt> (dump to stdout) *)

open Hardcaml
module Fp = Risc5.Fp_adder

(* one op through the port sim: hold inputs, run, drain until stall drops, read z, release
   run (the same protocol as test_fp_adder and the C++ harness). *)
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

let () =
  let vectors_path = Sys.argv.(1) in
  let module Sim = Cyclesim.With_interface (Fp.I) (Fp.O) in
  let sim = Sim.create Fp.create in
  let n = ref 0 in
  let emit ~u ~v ~x ~y =
    incr n;
    Printf.printf "%08X %08X %d %d %08X\n" x y u v (run_fp_add sim ~u ~v ~x ~y)
  in
  (* (a) corner stimuli: the frozen A-lines (the expected-z column is ignored) *)
  let ic = open_in vectors_path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
      try
        while true do
          match
            String.split_on_char ' ' (input_line ic) |> List.filter (fun s -> s <> "")
          with
          | [ "A"; x; y; u; v; _ ] ->
            let h s = int_of_string ("0x" ^ s) in
            emit ~u:(h u) ~v:(h v) ~x:(h x) ~y:(h y)
          | _ -> ()
        done
      with
      | End_of_file -> ());
  (* (b) fuzz: deterministic random x/y/u/v for breadth — covers all u,v including the
     unused u=v=1 op, where the port mirrors FPAdder.v too. *)
  let rng = Random.State.make [| 0xF9_AD |] in
  let rand32 () =
    (Random.State.int rng 0x10000 lsl 16) lor Random.State.int rng 0x10000
  in
  for _ = 1 to 20000 do
    emit
      ~u:(Random.State.int rng 2)
      ~v:(Random.State.int rng 2)
      ~x:(rand32 ())
      ~y:(rand32 ())
  done;
  Printf.eprintf "dump_fp_adder: %d stimuli (fp_vectors A-lines + 20000 fuzz)\n" !n
;;

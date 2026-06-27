open! Base
open Hardcaml

(* Build one of our Hardcaml units as a [Circuit.t] whose ports are named per its I/O
   interface — so the port names line up with the reference Verilog's, which is how [Sec]
   pairs the two sides. *)
let left_shifter () =
  let module C = Circuit.With_interface (Risc5.Left_shifter.I) (Risc5.Left_shifter.O) in
  C.create_exn ~name:"LeftShifter" Risc5.Left_shifter.create
;;

(* Each case: a label, a thunk building our circuit, the reference [.v] basename, and the
   Verilog top module name. Adding a combinational unit (RightShifter, ALU) is a new row. *)
let cases : (string * (unit -> Circuit.t) * string * string) list =
  [ "left_shifter", left_shifter, "LeftShifter.v", "LeftShifter" ]
;;

let () =
  let work_dir =
    (match Stdlib.Sys.getenv_opt "CLAUDE_JOB_DIR" with
     | Some d -> d
     | None -> "/tmp")
    ^ "/oberon-formal"
  in
  let rtl_dir = "_po/verilog/src" in
  let failures =
    List.count cases ~f:(fun (name, ours, v, top_module) ->
      let verilog = rtl_dir ^ "/" ^ v in
      Stdio.printf "=== %s : ours  vs  %s ===\n%!" name v;
      match Formal_equiv.check ~work_dir ~verilog ~top_module ~ours:(ours ()) with
      | Equivalent ->
        Stdio.printf
          "  EQUIVALENT  (proven by z3 — no input makes the outputs differ)\n%!";
        false
      | Counterexample ->
        Stdio.printf "  NOT EQUIVALENT  (counterexample found)\n%!";
        true)
  in
  if failures > 0
  then (
    Stdio.printf "\n%d formal check(s) FAILED\n" failures;
    Stdlib.exit 1)
  else Stdio.printf "\nall %d formal check(s) passed\n" (List.length cases)
;;

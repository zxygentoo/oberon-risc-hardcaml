open! Base
open Hardcaml

(* ── Combinational units: our circuit's ports match the reference .v; proven by importing
   the .v and SAT-checking against ours with hardcaml_verify's Sec + z3 (Formal_equiv). ── *)

let left_shifter () =
  let module C = Circuit.With_interface (Risc5.Left_shifter.I) (Risc5.Left_shifter.O) in
  C.create_exn ~name:"LeftShifter" Risc5.Left_shifter.create
;;

let right_shifter () =
  let module C = Circuit.With_interface (Risc5.Right_shifter.I) (Risc5.Right_shifter.O) in
  C.create_exn ~name:"RightShifter" Risc5.Right_shifter.create
;;

(* ── Sequential units: built with ports named to match the .v (clk/run/u/x/y → stall/z)
   and registers named to match (S/P, in the lib) so yosys equiv_make can pair the
   flip-flops; proven by emitting our Verilog and running yosys equiv_induct
   (Yosys_equiv). The circuit is named distinctly from the reference module so yosys can
   read both. ── *)

let multiplier () =
  let open Signal in
  let i =
    { Risc5.Multiplier.I.clock = input "clk" 1
    ; run = input "run" 1
    ; u = input "u" 1
    ; x = input "x" 32
    ; y = input "y" 32
    }
  in
  let { Risc5.Multiplier.O.stall; z } = Risc5.Multiplier.create i in
  Circuit.create_exn ~name:"multiplier_ours" [ output "stall" stall; output "z" z ]
;;

let divider () =
  let open Signal in
  let i =
    { Risc5.Divider.I.clock = input "clk" 1
    ; run = input "run" 1
    ; u = input "u" 1
    ; x = input "x" 32
    ; y = input "y" 32
    }
  in
  let { Risc5.Divider.O.stall; quot; rem } = Risc5.Divider.create i in
  Circuit.create_exn
    ~name:"divider_ours"
    [ output "stall" stall; output "quot" quot; output "rem" rem ]
;;

let fp_adder () =
  let open Signal in
  let i =
    { Risc5.Fp_adder.I.clock = input "clk" 1
    ; run = input "run" 1
    ; u = input "u" 1
    ; v = input "v" 1
    ; x = input "x" 32
    ; y = input "y" 32
    }
  in
  let { Risc5.Fp_adder.O.stall; z } = Risc5.Fp_adder.create i in
  Circuit.create_exn ~name:"fp_adder_ours" [ output "stall" stall; output "z" z ]
;;

let fp_multiplier () =
  let open Signal in
  let i =
    { Risc5.Fp_multiplier.I.clock = input "clk" 1
    ; run = input "run" 1
    ; x = input "x" 32
    ; y = input "y" 32
    }
  in
  let { Risc5.Fp_multiplier.O.stall; z } = Risc5.Fp_multiplier.create i in
  Circuit.create_exn ~name:"fp_multiplier_ours" [ output "stall" stall; output "z" z ]
;;

let fp_divider () =
  let open Signal in
  let i =
    { Risc5.Fp_divider.I.clock = input "clk" 1
    ; run = input "run" 1
    ; x = input "x" 32
    ; y = input "y" 32
    }
  in
  let { Risc5.Fp_divider.O.stall; z } = Risc5.Fp_divider.create i in
  Circuit.create_exn ~name:"fp_divider_ours" [ output "stall" stall; output "z" z ]
;;

(* ── Runner ── *)

let work_dir =
  (match Stdlib.Sys.getenv_opt "CLAUDE_JOB_DIR" with
   | Some d -> d
   | None -> "/tmp")
  ^ "/oberon-formal"
;;

let rtl_dir = "_po/verilog/src"

let run_combinational (name, ours, v, top_module) =
  Stdio.printf "=== %s : ours  vs  %s   [combinational · Sec/z3] ===\n%!" name v;
  match
    Formal_equiv.check ~work_dir ~verilog:(rtl_dir ^ "/" ^ v) ~top_module ~ours:(ours ())
  with
  | Formal_equiv.Equivalent ->
    Stdio.printf "  EQUIVALENT  (no input makes the outputs differ)\n%!";
    false
  | Formal_equiv.Counterexample ->
    Stdio.printf "  NOT EQUIVALENT  (counterexample found)\n%!";
    true
;;

let run_sequential (name, ours, v, top_module) =
  Stdio.printf "=== %s : ours  vs  %s   [sequential · yosys equiv_induct] ===\n%!" name v;
  match
    Yosys_equiv.check ~work_dir ~verilog:(rtl_dir ^ "/" ^ v) ~top_module ~ours:(ours ())
  with
  | Yosys_equiv.Equivalent ->
    Stdio.printf "  EQUIVALENT  (induction closed — all $equiv proven)\n%!";
    false
  | Yosys_equiv.Not_equivalent ->
    Stdio.printf "  NOT EQUIVALENT  ($equiv cells left unproven)\n%!";
    true
;;

let combinational : (string * (unit -> Circuit.t) * string * string) list =
  [ "left_shifter", left_shifter, "LeftShifter.v", "LeftShifter"
  ; "right_shifter", right_shifter, "RightShifter.v", "RightShifter"
  ]
;;

let sequential : (string * (unit -> Circuit.t) * string * string) list =
  [ "multiplier", multiplier, "Multiplier.v", "Multiplier"
  ; "divider", divider, "Divider.v", "Divider"
  ; "fp_adder", fp_adder, "FPAdder.v", "FPAdder"
  ; "fp_multiplier", fp_multiplier, "FPMultiplier.v", "FPMultiplier"
  ; "fp_divider", fp_divider, "FPDivider.v", "FPDivider"
  ]
;;

let () =
  let fails =
    List.count combinational ~f:run_combinational
    + List.count sequential ~f:run_sequential
  in
  let total = List.length combinational + List.length sequential in
  if fails > 0
  then (
    Stdio.printf "\n%d of %d formal check(s) FAILED\n" fails total;
    Stdlib.exit 1)
  else Stdio.printf "\nall %d formal check(s) passed\n" total
;;

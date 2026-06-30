open! Base
module Hov = Hardcaml_of_verilog

type result =
  | Equivalent
  | Counterexample

(* Drive yosys ourselves rather than via [Hardcaml_of_verilog.Synthesize]. Reason: yosys
   0.65 emits cell parameters as binary strings by default, which hardcaml_of_verilog's
   techlib rejects ("expecting int parameter"); [write_json -compat-int] emits them as
   JSON numbers instead, but hardcaml_of_verilog's built-in script omits the flag. We
   replicate its default lowering passes (proc/flatten/memory/opt/clean) and add
   [-compat-int], then feed the JSON into its exposed
   [Yosys_netlist.of_string -> Netlist -> Verilog_circuit] path — so no fork of
   hardcaml_of_verilog is needed. *)
let import ~work_dir ~verilog ~top_module =
  ignore
    (Stdlib.Sys.command (Printf.sprintf "mkdir -p %s" (Stdlib.Filename.quote work_dir)));
  let json = Printf.sprintf "%s/%s.json" work_dir top_module in
  let script = Printf.sprintf "%s/%s.ys" work_dir top_module in
  Stdio.Out_channel.write_all
    script
    ~data:
      (String.concat
         ~sep:"\n"
         [ "read_verilog -defer " ^ verilog
         ; "hierarchy -top " ^ top_module
         ; "proc"
         ; "flatten"
         ; "memory -nomap"
         ; "opt"
         ; "clean"
         ; "opt -mux_undef"
         ; "clean"
         ; "write_json -compat-int " ^ json
         ; ""
         ]);
  let rc =
    Stdlib.Sys.command (Printf.sprintf "yosys -q -s %s" (Stdlib.Filename.quote script))
  in
  if rc <> 0 then failwith (Printf.sprintf "yosys failed (exit %d) on %s" rc verilog);
  Stdio.In_channel.read_all json
  |> Hov.Expert.Yosys_netlist.of_string
  |> Or_error.ok_exn
  |> Hov.Netlist.of_yosys_netlist
  |> Or_error.ok_exn
  |> Hov.Verilog_circuit.create ~top_name:top_module
  |> Or_error.ok_exn
  |> Hov.Verilog_circuit.to_hardcaml_circuit
  |> Or_error.ok_exn
;;

(* Combinational equivalence of two in-process Hardcaml circuits (no .v import) — for a
   property checked against a spec we WRITE in Hardcaml rather than a reference .v (e.g.
   the VID look-ahead address ≡ a geometry spec). Sec builds the miter and SAT-checks it
   with z3; it pairs by port name, so [ours] and [spec] must share input/output names. *)
let check_circuits ~ours ~spec =
  let sec = Hardcaml_verify.Sec.create ours spec |> Or_error.ok_exn in
  match Hardcaml_verify.Sec.circuits_equivalent sec |> Or_error.ok_exn with
  | Unsat -> Equivalent
  | Sat _ -> Counterexample
;;

let check ~work_dir ~verilog ~top_module ~ours =
  check_circuits ~ours ~spec:(import ~work_dir ~verilog ~top_module)
;;

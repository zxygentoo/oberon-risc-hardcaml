open! Base
module Hov = Hardcaml_of_verilog

type result =
  | Equivalent
  | Counterexample

(* yosys is driven here and not through [Hardcaml_of_verilog.Synthesize]. yosys 0.65
   writes cell parameters as binary strings, which the importer's techlib rejects
   ("expecting int parameter"); [write_json -compat-int] writes them as numbers, but the
   importer's own script does not pass the flag. So its lowering passes (proc, flatten,
   memory, opt, clean) are repeated here with the flag added, and the JSON goes in through
   the public [Yosys_netlist.of_string] path: no fork of the importer is needed. *)
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

(* [Sec] builds the miter and z3 checks it; ports are paired by name. *)
let check_circuits ~ours ~spec =
  let sec = Hardcaml_verify.Sec.create ours spec |> Or_error.ok_exn in
  match Hardcaml_verify.Sec.circuits_equivalent sec |> Or_error.ok_exn with
  | Unsat -> Equivalent
  | Sat _ -> Counterexample
;;

let check ~work_dir ~verilog ~top_module ~ours =
  check_circuits ~ours ~spec:(import ~work_dir ~verilog ~top_module)
;;

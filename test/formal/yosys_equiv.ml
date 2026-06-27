open! Base
open Hardcaml

type result =
  | Equivalent
  | Not_equivalent

let emit_verilog circuit file =
  let rope = Rtl.create Verilog [ circuit ] |> Rtl.full_hierarchy in
  Stdio.Out_channel.write_all file ~data:(Rope.to_string rope)
;;

let check ~work_dir ~verilog ~top_module ~ours =
  ignore
    (Stdlib.Sys.command (Printf.sprintf "mkdir -p %s" (Stdlib.Filename.quote work_dir))
     : int);
  (* Emit our circuit; its module name (distinct from [top_module]) is the [gate] side. *)
  let gate = Circuit.name ours in
  let ours_v = Printf.sprintf "%s/%s.v" work_dir gate in
  emit_verilog ours ours_v;
  (* yosys SEC: build a miter pairing FFs by name, then prove the step by induction.
     [equiv_status -assert] exits non-zero iff any [$equiv] cell is left unproven. *)
  let script = Printf.sprintf "%s/%s.ys" work_dir top_module in
  Stdio.Out_channel.write_all
    script
    ~data:
      (String.concat
         ~sep:"\n"
         [ "read_verilog " ^ verilog
         ; "read_verilog " ^ ours_v
         ; "proc"
           (* lower any [$mem] to flip-flops so [equiv_make] can pair the memory state by
              name (needed for the register-file behavioural proof; a no-op for the
              memory-less iterative units). *)
         ; "memory"
         ; "opt"
         ; "equiv_make " ^ top_module ^ " " ^ gate ^ " equiv"
         ; "hierarchy -top equiv"
         ; "opt -full"
         ; "equiv_simple"
         ; "equiv_induct"
         ; "equiv_status -assert"
         ; ""
         ]);
  match
    Stdlib.Sys.command (Printf.sprintf "yosys -q -s %s" (Stdlib.Filename.quote script))
  with
  | 0 -> Equivalent
  | _ -> Not_equivalent
;;

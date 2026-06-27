open! Base
open Hardcaml

type result =
  | Equivalent
  | Not_equivalent

let emit_verilog circuit file =
  let rope = Rtl.create Verilog [ circuit ] |> Rtl.full_hierarchy in
  Stdio.Out_channel.write_all file ~data:(Rope.to_string rope)
;;

(* yosys [rename]s applied to our [gate] module so its register/net names match the
   reference's, letting [equiv_make] pair the state. Empty ⇒ no block emitted (the names
   already match, e.g. the iterative units and RS232T). Run before [equiv_make] (and
   before [memory], so a renamed [$mem] lowers to FFs that pair by name). *)
let rename_block ~gate ~renames =
  if List.is_empty renames
  then []
  else
    (("cd " ^ gate)
     :: List.map renames ~f:(fun (old, new_) -> Printf.sprintf "rename %s %s" old new_))
    @ [ "cd .." ]
;;

let check ~work_dir ~verilog ~renames ~top_module ~ours =
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
         ([ "read_verilog " ^ verilog; "read_verilog " ^ ours_v; "proc" ]
          @ rename_block ~gate ~renames
          @ [ (* lower any [$mem] to flip-flops so [equiv_make] can pair the memory state
                 by name (needed for the register-file behavioural proof and PS2's fifo; a
                 no-op for the memory-less iterative units). *)
              "memory"
            ; "opt"
            ; "equiv_make " ^ top_module ^ " " ^ gate ^ " equiv"
            ; "hierarchy -top equiv"
            ; "opt -full"
            ; "equiv_simple"
            ; "equiv_induct"
            ; "equiv_status -assert"
            ; ""
            ]));
  match
    Stdlib.Sys.command (Printf.sprintf "yosys -q -s %s" (Stdlib.Filename.quote script))
  with
  | 0 -> Equivalent
  | _ -> Not_equivalent
;;

let check_shim ~work_dir ~verilog ~shims ~gold_shim ~ours_shim ~renames ~ours =
  ignore
    (Stdlib.Sys.command (Printf.sprintf "mkdir -p %s" (Stdlib.Filename.quote work_dir))
     : int);
  let gate = Circuit.name ours in
  let ours_v = Printf.sprintf "%s/%s.v" work_dir gate in
  emit_verilog ours ours_v;
  (* Open-drain shim proof (AGENT.md §6, README Tier 2 — the Mouse). The reference
     [MouseP] has bidirectional open-drain [inout msclk, msdat]; our gate splits each into
     a [*_oe] drive + a resolved-value input. Both are wrapped ([shims]) into one explicit
     interface whose external read is a FREE input and whose observable is the resolved
     line; we then prove the wrapped pair equivalent. The tristate handling (the inout's
     whole reason for a shim) is: [tribuf -formal] lowers ALL tristate (incl. the
     inout-port drivers) to logic, [chformal -remove] drops tribuf's "no two drivers"
     assertion (illegal for open-drain wire-AND, which has many low drivers), and
     [setundef -one] ties the both-released float to 1 (the pad pull-up) — together
     exactly [line = oe ? 0 : ext] on both sides. The shim modules are flattened so the
     wrapped FFs surface, then renamed to the RTL's (stripping the [g.] instance prefix)
     so [equiv_make] pairs them. *)
  let script = Printf.sprintf "%s/mouse_shim.ys" work_dir in
  Stdio.Out_channel.write_all
    script
    ~data:
      (String.concat
         ~sep:"\n"
         ([ "read_verilog " ^ verilog
          ; "read_verilog " ^ shims
          ; "read_verilog " ^ ours_v
          ; "hierarchy -check"
          ; "proc"
          ; "flatten " ^ gold_shim
          ; "flatten " ^ ours_shim
          ; "tribuf -formal"
          ; "chformal -remove"
          ; "setundef -one"
          ]
          @ rename_block ~gate:gold_shim ~renames
          @ rename_block ~gate:ours_shim ~renames
          @ [ "memory"
            ; "opt"
            ; "equiv_make " ^ gold_shim ^ " " ^ ours_shim ^ " equiv"
            ; "hierarchy -top equiv"
            ; "opt -full"
            ; "equiv_simple"
            ; "equiv_induct"
            ; "equiv_status -assert"
            ; ""
            ]));
  match
    Stdlib.Sys.command (Printf.sprintf "yosys -q -s %s" (Stdlib.Filename.quote script))
  with
  | 0 -> Equivalent
  | _ -> Not_equivalent
;;

let check_core ~work_dir ~verilog ~stubs ~renames ~top_module ~ours =
  ignore
    (Stdlib.Sys.command (Printf.sprintf "mkdir -p %s" (Stdlib.Filename.quote work_dir))
     : int);
  let gate = Circuit.name ours in
  let ours_v = Printf.sprintf "%s/%s.v" work_dir gate in
  emit_verilog ours ours_v;
  (* In-situ glue proof (AGENT.md §6, README): the whole core minus its 8 submodules,
     which are black boxes on both sides ([stubs]). equiv_make pairs the top flip-flops
     (after we rename ours to RISC5.v's names) and MERGES the matched black-box cells —
     checking their inputs via the [$equiv] on the named nets. [cutpoint -blackbox] then
     replaces the merged units with shared free signals (the assume side: each unit is
     proven separately), leaving a pure glue netlist that equiv_simple + equiv_induct
     discharge. *)
  let script = Printf.sprintf "%s/%s_core.ys" work_dir top_module in
  Stdio.Out_channel.write_all
    script
    ~data:
      (String.concat
         ~sep:"\n"
         ([ "read_verilog " ^ stubs
          ; "read_verilog " ^ verilog
          ; "read_verilog " ^ ours_v
          ; "hierarchy -check"
          ; "proc"
          ]
          @ rename_block ~gate ~renames
          @ [ "opt"
            ; "equiv_make " ^ top_module ^ " " ^ gate ^ " equiv"
            ; "hierarchy -top equiv"
            ; "cutpoint -blackbox"
            ; "opt -full"
            ; "equiv_simple"
            ; "equiv_induct"
            ; "equiv_status -assert"
            ; ""
            ]));
  match
    Stdlib.Sys.command (Printf.sprintf "yosys -q -s %s" (Stdlib.Filename.quote script))
  with
  | 0 -> Equivalent
  | _ -> Not_equivalent
;;

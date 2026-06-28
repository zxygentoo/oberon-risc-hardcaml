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

(* The [rename_block] joined into one string, for splicing into a [{renames}] template
   placeholder (see [run_proof]); [""] when there are no renames. *)
let renames_block ~gate ~renames = String.concat ~sep:"\n" (rename_block ~gate ~renames)

(* Generic, template-driven proof driver (AGENT.md §6): every formal check is this one
   function + a checked-in [.ys.template] (test/formal/proofs/). It emits [ours] to Verilog,
   substitutes [{key}] -> value (the caller's [subst] plus the harness-owned [{ours}] = the
   emitted path, [{gate}] = its module name, [{smt2}] = an output path), writes the CONCRETE
   script to [work_dir] (so the exact proof that ran stays inspectable + runnable), runs
   yosys, and maps the exit code.

   [smtbmc] handles the one property proof (the VID CDC invariant): there the template only
   emits an SMT problem to [{smt2}], so yosys success means nothing — the verdict is the
   k-induction, and we run [yosys-smtbmc -i -t smtbmc] on [{smt2}] and map ITS exit instead.

   A real yosys command never contains a literal '{', so any brace surviving substitution is
   an unfilled placeholder (a template/[subst] mismatch) — we raise on it rather than let
   yosys choke. Substitution is blind (it ignores '#' comments), so a template must keep
   [{placeholder}]s at their substitution site ONLY, never inside a comment — a multi-line
   value (a rename block) spliced into a comment line would break it. *)
let run_proof ~work_dir ~ours ~template ~subst ?smtbmc () =
  ignore
    (Stdlib.Sys.command (Printf.sprintf "mkdir -p %s" (Stdlib.Filename.quote work_dir))
     : int);
  let gate = Circuit.name ours in
  let ours_v = Printf.sprintf "%s/%s.v" work_dir gate in
  emit_verilog ours ours_v;
  let smt2 = Printf.sprintf "%s/out.smt2" work_dir in
  let subst = ("ours", ours_v) :: ("gate", gate) :: ("smt2", smt2) :: subst in
  let body =
    List.fold subst ~init:(Stdio.In_channel.read_all template) ~f:(fun acc (k, v) ->
      String.substr_replace_all acc ~pattern:("{" ^ k ^ "}") ~with_:v)
  in
  (match String.index body '{' with
   | None -> ()
   | Some i ->
     let j =
       Option.value (String.index_from body i '}') ~default:(String.length body - 1)
     in
     failwith
       (Printf.sprintf
          "run_proof: %s left an unsubstituted placeholder %s"
          template
          (String.sub body ~pos:i ~len:(j - i + 1))));
  let script = Printf.sprintf "%s/proof.ys" work_dir in
  Stdio.Out_channel.write_all script ~data:body;
  let sh cmd = Stdlib.Sys.command cmd in
  match sh (Printf.sprintf "yosys -q -s %s" (Stdlib.Filename.quote script)), smtbmc with
  | 0, None -> Equivalent
  | 0, Some depth ->
    (match
       sh
         (Printf.sprintf
            "yosys-smtbmc -i -s z3 -t %d %s > /dev/null 2>&1"
            depth
            (Stdlib.Filename.quote smt2))
     with
     | 0 -> Equivalent
     | _ -> Not_equivalent)
  | _, _ -> Not_equivalent
;;

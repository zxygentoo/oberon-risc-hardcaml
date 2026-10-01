open! Base
open Hardcaml

type result =
  | Equivalent
  | Not_equivalent

let emit_verilog circuit file =
  let rope = Rtl.create Verilog [ circuit ] |> Rtl.full_hierarchy in
  Stdio.Out_channel.write_all file ~data:(Rope.to_string rope)
;;

(* The yosys [rename]s that give our [gate] module the reference's register and net names;
   nothing is emitted when there are none. They run before [equiv_make], and before
   [memory], so that a renamed [$mem] lowers to flip-flops that pair by name. *)
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

(* The contract is in the .mli. Three notes on the implementation.

   The script written to [work_dir] is the concrete one, so the exact proof that ran can
   be read and rerun.

   For [smtbmc] both halves of the induction are needed. The step alone starts from
   arbitrary states and never visits reset; and the base case runs with [--presat], so
   that unsatisfiable assumptions cannot pass vacuously.

   A yosys command never contains a literal '{', so a brace that survives substitution is
   a placeholder nobody filled, and we raise instead of letting yosys choke on it.
   Substitution is blind to '#' comments: a template must keep each placeholder at its
   substitution site only, never in a comment, where a multi-line value (a rename block)
   would break the script. *)
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
    let smtbmc mode =
      sh
        (Printf.sprintf
           "yosys-smtbmc %s -s z3 -t %d %s > %s/smtbmc%s.log 2>&1"
           mode
           depth
           (Stdlib.Filename.quote smt2)
           (Stdlib.Filename.quote work_dir)
           (String.strip mode ~drop:(Char.equal '-')))
    in
    if smtbmc "--presat" = 0 && smtbmc "-i" = 0 then Equivalent else Not_equivalent
  | _, _ -> Not_equivalent
;;

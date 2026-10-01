(* Public contract in [disk.mli]. *)

(* Locate the project root by walking up for [dune-project], so the disk resolves from any
   cwd — the gates' rules (which run under [_build]) and a bare [dune exec] from the repo
   root alike. (dune does NOT mirror [dune-project] into [_build/default], so the walk
   climbs out of [_build] and lands at the real root every time; the rules' declared disk
   dep is a rebuild trigger, not the copy that gets read.) *)
let project_root () =
  let rec up dir =
    if Sys.file_exists (Filename.concat dir "dune-project")
    then dir
    else (
      let parent = Filename.dirname dir in
      if String.equal parent dir
      then failwith "Boot.Disk: no dune-project found above cwd"
      else up parent)
  in
  up (Sys.getcwd ())
;;

let custom = Option.is_some (Sys.getenv_opt "DISK_IMG")

let image =
  match Sys.getenv_opt "DISK_IMG" with
  | Some p -> p
  | None ->
    Filename.concat
      (project_root ())
      "vendor/oberon-risc-emu-ocaml/DiskImage/Oberon-2020-08-18.dsk"
;;

let copy_to_temp src =
  let tmp = Filename.temp_file "boot_" ".dsk" in
  let ic = open_in_bin src
  and oc = open_out_bin tmp in
  output_string oc (really_input_string ic (in_channel_length ic));
  close_in ic;
  close_out oc;
  tmp
;;

let rm_temp tmp =
  try Sys.remove tmp with
  | Sys_error _ -> ()
;;

(* Parallel RTL-fidelity co-sim runner (replaces the old run.sh + run-core.sh).

   Asserts each Hardcaml unit is bit- and cycle-exact to its reference Verilog via
   Verilator, over every unit at once: the shared prep (RTL fetch + dumper/exe builds)
   runs once up front, then each unit runs in its own forked worker — output captured to
   test/_work/cosim/<unit>/ run.log — throttled to a bounded pool. A PASS/FAIL summary
   (with the tail of any failing log) prints at the end; exit is nonzero iff any unit
   failed.

   Two unit shapes, one runner:
   - Stimulus units (FP x3, SPI, RS232 T/R, PS2, VID, mouse): dump the port's outputs over
     a stimulus set, verilate the reference .v + harness, cross-check (value AND timing).
     The .cpp self-asserts (exits nonzero on mismatch).
   - The CPU core: a whole-boot capture-and-replay — capture the core's per-cycle I/O over
     a real Oberon boot (test/core_dump.exe; ~2 M cycles by default, ~10 s, cached as a
     ~33 MiB trace) and replay it through RISC5.v + submodules, reporting the first cycle
     our port diverges (skips the 2-cycle reset transient; see core.cpp).

   OPT-IN — not part of [dune runtest]. Needs [verilator] on PATH. The reference Verilog
   is fetched + checksum-verified on demand by ../fetch-rtl.sh (toolchain-free). Front
   door: [dune build @cosim] runs every unit (the 9 + the core) in parallel;
   [dune exec test/cosim/cosim_run.exe -- <unit>] runs one live (uncaptured) for
   debugging; a trailing count ([-- all 4]) caps the job pool. *)

let repo_root =
  let rec up d =
    if Sys.file_exists (Filename.concat d "dune-project")
    then d
    else (
      let p = Filename.dirname d in
      if String.equal p d then failwith "cosim_run: no dune-project above cwd" else up p)
  in
  up (Sys.getcwd ())
;;

let () = Sys.chdir repo_root (* all paths below are repo-root-relative *)
let rtl_dir = "test/_po/verilog/src"
let cosim_dir = "test/cosim"
let work_root = "test/_work/cosim"
let vec = "vendor/oberon-risc-emu-ocaml/test/data/fp_vectors.txt"

(* one row per unit; the variant lets the core's different shape share the same runner *)
type kind =
  | Stimulus of
      { rtl : string (* reference .v in rtl_dir *)
      ; top : string (* Verilator top module *)
      ; cpp : string (* harness in cosim_dir *)
      ; dumper : string (* dune exe in cosim_dir; "fp_dump" alone takes <name> <vec> *)
      ; extra : string option
      (* extra .v in cosim_dir handed to Verilator (vid/mouse wrappers) *)
      }
  | Core of
      { rtls : string list (* .v in rtl_dir: RISC5.v + its 8 submodules *)
      ; extra_v : string list (* .v in cosim_dir: ram16x1d.v (the inferred primitive) *)
      ; cpp : string
      ; top : string
      ; skip : int (* leading reset-transient cycles to compared-skip *)
      }

type spec =
  { name : string
  ; kind : kind
  }

let stim name rtl top cpp dumper extra =
  { name; kind = Stimulus { rtl; top; cpp; dumper; extra } }
;;

let units =
  [ stim "fp_adder" "FPAdder.v" "FPAdder" "fp_adder.cpp" "fp_dump" None
  ; stim
      "fp_multiplier"
      "FPMultiplier.v"
      "FPMultiplier"
      "fp_multiplier.cpp"
      "fp_dump"
      None
  ; stim "fp_divider" "FPDivider.v" "FPDivider" "fp_divider.cpp" "fp_dump" None
  ; stim "spi" "SPI.v" "SPI" "spi.cpp" "spi_dump" None
  ; stim "rs232t" "RS232T.v" "RS232T" "rs232t.cpp" "rs232_dump" None
  ; stim "rs232r" "RS232R.v" "RS232R" "rs232r.cpp" "rs232_dump" None
  ; stim "ps2" "PS2.v" "PS2" "ps2.cpp" "ps2_dump" None
  ; stim "vid" "VID60.v" "vid_cosim" "vid.cpp" "vid_dump" (Some "vid_cosim.v")
  ; stim "mouse" "MousePM.v" "mouse_cosim" "mouse.cpp" "mouse_dump" (Some "mouse_cosim.v")
  ; { name = "core"
    ; kind =
        Core
          { rtls =
              [ "RISC5.v"
              ; "Registers.v"
              ; "Multiplier.v"
              ; "Divider.v"
              ; "LeftShifter.v"
              ; "RightShifter.v"
              ; "FPAdder.v"
              ; "FPMultiplier.v"
              ; "FPDivider.v"
              ]
          ; extra_v = [ "ram16x1d.v" ]
          ; cpp = "core.cpp"
          ; top = "RISC5"
          ; skip = 2
          }
    }
  ]
;;

(* ── shell helpers (used inside each forked worker, where stdout/stderr point at the log)
   ── *)
let quote = Filename.quote
let abs p = Filename.concat repo_root p

let sh cmd =
  flush stdout;
  flush stderr;
  Sys.command cmd
;;

let mkdir_p d = ignore (sh (Printf.sprintf "mkdir -p %s" (quote d)) : int)

(* verilate sources -> <objdir>/cosim; self-healing: on failure nuke obj_dir and retry
   once on a clean tree (recovers a stale/partial obj_dir or a verilator flake). Returns 0
   on success. *)
let verilate ~top ~objdir ~sources ~vlog =
  let cmd =
    Printf.sprintf
      "verilator --cc --exe --build -Wno-fatal --top-module %s --Mdir %s %s -o cosim > \
       %s 2>&1"
      (quote top)
      (quote objdir)
      (String.concat " " (List.map quote sources))
      (quote vlog)
  in
  if sh cmd = 0
  then 0
  else (
    Printf.printf "    verilate failed — cleaning obj_dir and retrying once ...\n";
    ignore (sh (Printf.sprintf "rm -rf %s" (quote objdir)) : int);
    if sh cmd = 0
    then 0
    else (
      Printf.printf "ERROR: verilator failed:\n";
      ignore (sh (Printf.sprintf "cat %s" (quote vlog)) : int);
      1))
;;

let run_stimulus name ~rtl ~top ~cpp ~dumper ~extra =
  let work = Filename.concat work_root name in
  mkdir_p work;
  Printf.printf
    "=== %s ===\n[1/3] dumping Hardcaml %s outputs over the stimulus set ...\n"
    name
    name;
  let dexe = Printf.sprintf "_build/default/test/cosim/%s.exe" dumper in
  (* shared dumpers take the unit name: fp_dump (all 3 FP units) also takes the fp_vectors
     path; rs232_dump picks tx/rx by name. The rest take no args. *)
  let dargs =
    if String.equal dumper "fp_dump"
    then Printf.sprintf "%s %s" name (quote vec)
    else if String.equal dumper "rs232_dump"
    then name
    else ""
  in
  let port = Filename.concat work "port.txt" in
  if sh (Printf.sprintf "%s %s > %s" (quote dexe) dargs (quote port)) <> 0
  then 1
  else (
    Printf.printf "[2/3] verilating %s + harness ...\n" rtl;
    let objdir = Filename.concat work "obj_dir" in
    let vlog = Filename.concat work "verilate.log" in
    let sources =
      [ abs (Filename.concat rtl_dir rtl) ]
      @ (match extra with
         | Some e -> [ abs (Filename.concat cosim_dir e) ]
         | None -> [])
      @ [ abs (Filename.concat cosim_dir cpp) ]
    in
    if verilate ~top ~objdir ~sources ~vlog <> 0
    then 1
    else (
      ignore (sh (Printf.sprintf "tail -2 %s" (quote vlog)) : int);
      Printf.printf "[3/3] cross-checking RTL vs port ...\n";
      sh (Printf.sprintf "%s %s" (quote (Filename.concat objdir "cosim")) (quote port))))
;;

let run_core name ~rtls ~extra_v ~cpp ~top ~skip =
  let work = Filename.concat work_root name in
  mkdir_p work;
  let trace = Filename.concat work "core_boot.trace" in
  Printf.printf "=== %s ===\n" name;
  let cap_ok =
    if Sys.file_exists trace && (Unix.stat trace).st_size > 0
    then (
      Printf.printf "[1/3] reusing cached trace %s (delete it to recapture)\n" trace;
      true)
    else (
      Printf.printf "[1/3] capturing core boot I/O -> %s (~10 s) ...\n" trace;
      sh (Printf.sprintf "CORE_TRACE=%s _build/default/test/core_dump.exe" (quote trace))
      = 0)
  in
  if not cap_ok
  then (
    Printf.printf "ERROR: core boot capture failed\n";
    1)
  else (
    Printf.printf "[2/3] verilating RISC5.v + submodules ...\n";
    let objdir = Filename.concat work "obj_dir" in
    let vlog = Filename.concat work "verilate.log" in
    let sources =
      List.map (fun v -> abs (Filename.concat rtl_dir v)) rtls
      @ List.map (fun v -> abs (Filename.concat cosim_dir v)) extra_v
      @ [ abs (Filename.concat cosim_dir cpp) ]
    in
    if verilate ~top ~objdir ~sources ~vlog <> 0
    then 1
    else (
      ignore (sh (Printf.sprintf "tail -3 %s" (quote vlog)) : int);
      Printf.printf "[3/3] replaying the boot trace through RISC5.v ...\n";
      sh
        (Printf.sprintf
           "%s %s %d"
           (quote (Filename.concat objdir "cosim"))
           (quote trace)
           skip)))
;;

let run_unit spec =
  match spec.kind with
  | Stimulus { rtl; top; cpp; dumper; extra } ->
    run_stimulus spec.name ~rtl ~top ~cpp ~dumper ~extra
  | Core { rtls; extra_v; cpp; top; skip } ->
    run_core spec.name ~rtls ~extra_v ~cpp ~top ~skip
;;

(* The parallel pool + PASS/FAIL summary live in the shared [Fork_pool] (fork_pool.mli),
   used by both this runner and test/formal. *)

(* build only the dumper/capture exes that are missing — so @cosim (which declares them as
   deps, pre-building them) never triggers a nested `dune build` inside the dune action. *)
let ensure_exes selected =
  let targets =
    List.filter_map
      (fun spec ->
        match spec.kind with
        | Stimulus { dumper; _ } ->
          if Sys.file_exists (Printf.sprintf "_build/default/test/cosim/%s.exe" dumper)
          then None
          else Some (Printf.sprintf "test/cosim/%s.exe" dumper)
        | Core _ ->
          if Sys.file_exists "_build/default/test/core_dump.exe"
          then None
          else Some "test/core_dump.exe")
      selected
    |> List.sort_uniq String.compare
  in
  match targets with
  | [] -> ()
  | _ ->
    Printf.printf "[cosim] building: %s\n%!" (String.concat " " targets);
    if sh (Printf.sprintf "dune build %s" (String.concat " " (List.map quote targets)))
       <> 0
    then (
      Printf.eprintf "[cosim] exe build failed\n";
      exit 2)
;;

let () =
  let argv = Sys.argv in
  let sel = if Array.length argv >= 2 then argv.(1) else "all" in
  let selected =
    if String.equal sel "all"
    then units
    else (
      match List.find_opt (fun s -> String.equal s.name sel) units with
      | Some s -> [ s ]
      | None ->
        Printf.eprintf
          "unknown unit: %s (expected %s | all)\n"
          sel
          (String.concat " " (List.map (fun s -> s.name) units));
        exit 2)
  in
  let jobs =
    if Array.length argv >= 3
    then (
      match int_of_string_opt argv.(2) with
      | Some j -> max 1 j
      | None ->
        Printf.eprintf "bad jobs count: %s\n" argv.(2);
        exit 2)
    else max 1 (min (Domain.recommended_domain_count ()) (List.length selected))
  in
  if sh "command -v verilator > /dev/null 2>&1" <> 0
  then (
    Printf.eprintf "error: verilator not on PATH\n";
    exit 2);
  (* prep, serialized before any fan-out *)
  if sh "bash test/fetch-rtl.sh" <> 0
  then (
    Printf.eprintf "[cosim] reference RTL fetch failed\n";
    exit 2);
  ensure_exes selected;
  match selected with
  | [ one ] -> exit (run_unit one) (* single unit: run live (uncaptured) for debugging *)
  | _ ->
    let fails =
      Fork_pool.run
        ~what:"cosim"
        ~jobs
        ~work_root
        (List.map (fun spec -> spec.name, fun () -> run_unit spec = 0) selected)
    in
    exit (if fails = 0 then 0 else 1)
;;

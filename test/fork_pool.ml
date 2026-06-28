(* Bounded forked-worker pool with a PASS/FAIL summary — see fork_pool.mli.

   Each job is forked into its own process whose stdout/stderr are redirected to its log,
   so workers run truly concurrently and their output never interleaves. The parent keeps
   at most [jobs] alive at once (launch until full, then reap one and launch the next),
   collecting exit codes for the summary. Jobs are subprocess-bound (verilator / yosys /
   z3), so fork + a fresh binary per job is both safe and the natural fit. *)

let mkdir_p d =
  ignore (Sys.command (Printf.sprintf "mkdir -p %s" (Filename.quote d)) : int)
;;

(* a worker: redirect this process's stdout/stderr to the job's log, run it, exit with its
   verdict *)
let worker ~work_root name run =
  let dir = Filename.concat work_root name in
  mkdir_p dir;
  let fd =
    Unix.openfile
      (Filename.concat dir "run.log")
      [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ]
      0o644
  in
  Unix.dup2 fd Unix.stdout;
  Unix.dup2 fd Unix.stderr;
  Unix.close fd;
  let ok =
    try run () with
    | e ->
      Printf.printf "EXN: %s\n" (Printexc.to_string e);
      false
  in
  flush stdout;
  flush stderr;
  exit (if ok then 0 else 1)
;;

let run ~what ~jobs ~work_root job_list =
  let total = List.length job_list in
  Printf.printf
    "[%s] running %d jobs, up to %d in parallel; per-job logs in %s/<name>/run.log\n%!"
    what
    total
    jobs
    work_root;
  let t0 = Unix.gettimeofday () in
  (* Live per-unit lines earn their keep only when stdout is a terminal (real-time
     progress as jobs finish). Under `dune build` the action's stdout is captured and
     flushed at the end, where they'd just duplicate the summary table — so gate them on a
     TTY. *)
  let live =
    try Unix.isatty Unix.stdout with
    | _ -> false
  in
  let queue = ref job_list in
  let running : (int, string * float) Hashtbl.t = Hashtbl.create 16 in
  let results = ref [] in
  let nonempty r =
    match !r with
    | [] -> false
    | _ -> true
  in
  let launch (name, run) =
    flush stdout;
    flush stderr;
    (* so the child doesn't inherit (and later re-flush) the parent's buffer *)
    let st = Unix.gettimeofday () in
    match Unix.fork () with
    | 0 -> worker ~work_root name run (* child: never returns *)
    | pid -> Hashtbl.replace running pid (name, st)
  in
  let reap () =
    let pid, status = Unix.wait () in
    match Hashtbl.find_opt running pid with
    | None -> ()
    | Some (name, st) ->
      Hashtbl.remove running pid;
      let code =
        match status with
        | Unix.WEXITED c -> c
        | _ -> 255
      in
      let dt = Unix.gettimeofday () -. st in
      results := (name, code, dt) :: !results;
      if live
      then
        if code = 0
        then Printf.printf "  [PASS] %-16s %4.0fs\n%!" name dt
        else
          Printf.printf
            "  [FAIL] %-16s %4.0fs  (see %s/run.log)\n%!"
            name
            dt
            (Filename.concat work_root name)
  in
  while nonempty queue || Hashtbl.length running > 0 do
    while Hashtbl.length running < jobs && nonempty queue do
      match !queue with
      | j :: rest ->
        queue := rest;
        launch j
      | [] -> ()
    done;
    if Hashtbl.length running > 0 then reap ()
  done;
  (* summary, in declaration order *)
  let results = !results in
  let result_of name = List.find_opt (fun (n, _, _) -> String.equal n name) results in
  let pass = ref 0
  and fail = ref 0 in
  Printf.printf "\n======== %s results ========\n" what;
  List.iter
    (fun (name, _) ->
      match result_of name with
      | Some (_, 0, dt) ->
        incr pass;
        Printf.printf "  PASS  %-16s %4.0fs\n" name dt
      | Some (_, _, dt) ->
        incr fail;
        Printf.printf "  FAIL  %-16s %4.0fs\n" name dt
      | None ->
        incr fail;
        Printf.printf "  FAIL  %-16s   (no result)\n" name)
    job_list;
  Printf.printf "----------------------------\n";
  Printf.printf
    "  %d passed, %d failed of %d  (wall %.0fs)\n"
    !pass
    !fail
    total
    (Unix.gettimeofday () -. t0);
  if !fail > 0
  then
    List.iter
      (fun (name, _) ->
        match result_of name with
        | Some (_, 0, _) -> ()
        | _ ->
          let log = Filename.concat (Filename.concat work_root name) "run.log" in
          Printf.printf "\n----- %s FAILED — tail of %s -----\n%!" name log;
          ignore (Sys.command (Printf.sprintf "tail -20 %s" (Filename.quote log)) : int))
      job_list;
  !fail
;;

(* See fork_pool.mli. *)

let mkdir_p d =
  ignore (Sys.command (Printf.sprintf "mkdir -p %s" (Filename.quote d)) : int)
;;

let cd_to_repo_root () =
  let rec up d =
    if Sys.file_exists (Filename.concat d "dune-project")
    then d
    else (
      let p = Filename.dirname d in
      if String.equal p d
      then failwith "cd_to_repo_root: no dune-project above cwd"
      else up p)
  in
  Sys.chdir (up (Sys.getcwd ()))
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
  (* the per-job lines are worth printing only on a terminal: under dune the output is
     captured and shown at the end, where they would repeat the summary *)
  let live =
    try Unix.isatty Unix.stdout with
    | _ -> false
  in
  let queue = ref job_list in
  let running : (int, string * float) Hashtbl.t = Hashtbl.create 16 in
  let results = ref [] in
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
  while (not (List.is_empty !queue)) || Hashtbl.length running > 0 do
    while Hashtbl.length running < jobs && not (List.is_empty !queue) do
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

(* Each worker marshals its result to a temp file the parent reads back once the worker
   has exited 0. The child leaves through [Unix._exit] so it never runs the parent's
   [at_exit] handlers. *)
let map ~jobs fs =
  let fs = Array.of_list fs in
  let files = Array.map (fun _ -> Filename.temp_file "fork_pool" ".bin") fs in
  let running : (int, int) Hashtbl.t = Hashtbl.create 16 in
  let failed = ref [] in
  let launch k =
    flush stdout;
    flush stderr;
    match Unix.fork () with
    | 0 ->
      let code =
        try
          let oc = open_out_bin files.(k) in
          Marshal.to_channel oc (fs.(k) ()) [];
          close_out oc;
          0
        with
        | e ->
          Printf.eprintf "fork_pool worker %d: %s\n" k (Printexc.to_string e);
          1
      in
      flush stdout;
      flush stderr;
      Unix._exit code
    | pid -> Hashtbl.replace running pid k
  in
  let reap () =
    let pid, status = Unix.wait () in
    match Hashtbl.find_opt running pid with
    | None -> ()
    | Some k ->
      Hashtbl.remove running pid;
      if status <> Unix.WEXITED 0 then failed := k :: !failed
  in
  let next = ref 0 in
  while !next < Array.length fs || Hashtbl.length running > 0 do
    while Hashtbl.length running < jobs && !next < Array.length fs do
      launch !next;
      incr next
    done;
    if Hashtbl.length running > 0 then reap ()
  done;
  let results =
    if List.is_empty !failed
    then
      Array.to_list
        (Array.map
           (fun file ->
             let ic = open_in_bin file in
             let v = Marshal.from_channel ic in
             close_in ic;
             v)
           files)
    else []
  in
  Array.iter Sys.remove files;
  match List.sort compare !failed with
  | [] -> results
  | ks ->
    failwith
      (Printf.sprintf
         "Fork_pool.map: worker(s) %s failed"
         (String.concat ", " (List.map string_of_int ks)))
;;

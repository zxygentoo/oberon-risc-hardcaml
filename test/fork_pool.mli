(** Named jobs run concurrently in a bounded pool of forked workers, with a PASS/FAIL
    summary: what the co-simulation and proof runners need.

    Each job runs in its own forked process, its output redirected to
    [<work_root>/<name>/run.log], and returns [true] on success. The parent keeps at most
    [jobs] alive, prints a line as each finishes, then a summary with the tail of every
    failing log, and returns the number of failures. [what] names the run. *)
val run
  :  what:string
  -> jobs:int
  -> work_root:string
  -> (string * (unit -> bool)) list
  -> int

(** change to the repository root, the nearest ancestor holding dune-project *)
val cd_to_repo_root : unit -> unit

(** [map ~jobs fs] evaluates every thunk of [fs] in its own forked process, at most [jobs]
    at a time, and returns the results in order — for independent, CPU-bound work (the
    board bench runs one simulated machine per worker). A result travels back through
    [Marshal], so it must be plain data (no closures). Workers share the parent's stdout
    and should stay quiet. A worker that raises or dies fails the whole call. *)
val map : jobs:int -> (unit -> 'a) list -> 'a list

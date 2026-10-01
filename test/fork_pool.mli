(** Run named jobs concurrently in a bounded pool of forked workers, with a PASS/FAIL
    summary.

    Shared by the opt-in RTL-fidelity runners (cosim's [cosim_run], formal's
    [formal_run]): both fan a list of independent, subprocess-bound jobs (verilator /
    yosys / z3) out across a bounded pool and report one summary.

    Each job runs in its own forked process with stdout/stderr redirected to
    [<work_root>/<name>/run.log]; the thunk returns [true] on success. The parent
    throttles to [jobs] workers at a time, prints a live result line as each finishes,
    then a summary table (with the tail of any failing log) and the wall time. Returns the
    number of jobs that failed (0 = all passed). [what] labels the run (e.g. ["cosim"],
    ["formal"]). *)
val run
  :  what:string
  -> jobs:int
  -> work_root:string
  -> (string * (unit -> bool)) list
  -> int

(** cd to the repo root (nearest ancestor with dune-project) — both runners launch from
    varying cwds and keep every path repo-root-relative *)
val cd_to_repo_root : unit -> unit

(** [map ~jobs fs] evaluates every thunk of [fs] in its own forked process, at most [jobs]
    at a time, and returns the results in order — for independent, CPU-bound work (the
    board bench runs one simulated machine per worker). A result travels back through
    [Marshal], so it must be plain data (no closures). Workers share the parent's stdout
    and should stay quiet. A worker that raises or dies fails the whole call. *)
val map : jobs:int -> (unit -> 'a) list -> 'a list

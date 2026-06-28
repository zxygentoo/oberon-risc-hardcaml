(** Run named jobs concurrently in a bounded pool of forked workers, with a PASS/FAIL
    summary.

    Shared by the opt-in RTL-fidelity runners (cosim's [cosim_run], formal's
    [test_formal]): both fan a list of independent, subprocess-bound jobs (verilator /
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

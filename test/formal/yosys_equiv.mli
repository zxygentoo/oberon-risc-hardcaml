(** Sequential equivalence, proven inside yosys.

    The counterpart of {!Formal_equiv} for units with state. Importing the reference and
    checking with [Sec] does not work for them: [Sec] pairs state by name, and the import
    mangles register names and grouping. So our circuit is emitted as Verilog and compared
    with the reference [.v] inside yosys: [equiv_make] pairs the flip-flops by name,
    [equiv_induct] proves by induction that from any common state the two take the same
    step, and [equiv_status -assert] requires every point closed. It needs only [yosys],
    whose SAT solver is built in.

    The requirement: our port names and register names must be the reference's, so that
    the state can be paired. The sequential units therefore name their registers after the
    RTL (the multiplier's [S] and [P], for example), and the caller builds the circuit
    with the [.v]'s port names. *)

open! Base
open Hardcaml

type result =
  | Equivalent (** every [$equiv] point proven by induction *)
  | Not_equivalent (** some point left unproven (a real or inductive counterexample) *)

(** [renames_block ~gate ~renames] renders the [cd <gate> / rename old new / cd ..] block
    (newline-joined, [""] when [renames = []]) for splicing into a [{renames}] placeholder
    of a {!run_proof} template. *)
val renames_block : gate:string -> renames:(string * string) list -> string

(** [run_proof ~work_dir ~ours ~template ~subst ?smtbmc ()] runs one proof: every check
    that goes through yosys is this function and a checked-in [.ys.template] under
    test/formal/proofs/. It emits [ours] as Verilog; substitutes each [{key}] of [subst]
    into the template, and three of its own ([{ours}], the emitted path; [{gate}], its
    module name; [{smt2}], an output path); writes the resulting script under [work_dir],
    where it can be read and rerun; runs yosys; and maps the exit code to {!result}. It
    raises if a placeholder is left unfilled.

    [smtbmc] is the depth [k] for the one property proof (the video request crossing),
    whose template only emits an SMT problem to [{smt2}]. There a successful yosys run is
    not the verdict: [run_proof] runs yosys-smtbmc on the problem twice — the base case
    (bounded model checking from the initial state for [k] steps, with [--presat]) and the
    induction step ([-i]) — and reports {!Equivalent} only if both succeed. *)
val run_proof
  :  work_dir:string
  -> ours:Circuit.t
  -> template:string
  -> subst:(string * string) list
  -> ?smtbmc:int
  -> unit
  -> result

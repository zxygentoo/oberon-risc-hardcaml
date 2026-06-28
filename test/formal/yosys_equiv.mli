(** Sequential logic-equivalence via yosys-native SEC (k-induction).

    The sequential counterpart to {!Formal_equiv}. For the stateful units (MUL/DIV/FP,
    eventually the core), the import-then-[Sec] approach hits a register-correspondence
    wall: [hardcaml_of_verilog] mangles register names/grouping, and [Sec] pairs state
    {e by name}. Instead, emit our circuit to Verilog ([Rtl]) and prove it equivalent to
    the reference [.v] {e inside yosys}: [equiv_make] pairs flip-flops by name,
    [equiv_induct] proves the step by temporal induction, [equiv_status -assert] checks
    every point closed. Needs only [yosys] (its built-in SAT) — no import, no z3.

    Requirement: our circuit's port {e and register} names must match the reference's, so
    [equiv_make] can pair the state. The sequential units therefore name their registers
    after the RTL (e.g. the Multiplier's [S]/[P]), and the driver builds the circuit with
    ports named to match the [.v]. *)

open! Base
open Hardcaml

type result =
  | Equivalent (** every [$equiv] point proven by induction *)
  | Not_equivalent (** some point left unproven (a real or inductive counterexample) *)

(** [renames_block ~gate ~renames] renders the [cd <gate> / rename old new / cd ..] block
    (newline-joined, [""] when [renames = []]) for splicing into a [{renames}] placeholder
    of a {!run_proof} template. *)
val renames_block : gate:string -> renames:(string * string) list -> string

(** [run_proof ~work_dir ~ours ~template ~subst ?smtbmc ()] is the generic,
    template-driven proof driver (AGENT.md §6) — every formal check is this one function +
    a checked-in [.ys.template] under test/formal/proofs/. It emits [ours] to Verilog,
    substitutes [{key} -> value] from [subst] (plus the harness-owned [{ours}] = the
    emitted path, [{gate}] = its module name, [{smt2}] = an output path) into [template],
    writes the concrete script under [work_dir] (inspectable + runnable), runs yosys, and
    maps the exit code to {!result}. Raises if any [{placeholder}] is left unsubstituted.

    [smtbmc] is the induction depth for the one property proof (the VID CDC invariant),
    whose template only emits an SMT problem to [{smt2}]: there yosys success is not the
    verdict, so [run_proof] runs [yosys-smtbmc -i -t smtbmc] on [{smt2}] and maps ITS
    exit. *)
val run_proof
  :  work_dir:string
  -> ours:Circuit.t
  -> template:string
  -> subst:(string * string) list
  -> ?smtbmc:int
  -> unit
  -> result

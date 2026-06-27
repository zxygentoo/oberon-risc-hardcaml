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

(** [check ~work_dir ~verilog ~top_module ~ours] proves [ours] sequentially equivalent to
    module [top_module] of file [verilog]. [ours] must be named distinctly from
    [top_module] (yosys reads both into one design), with its ports and registers named to
    match. *)
val check
  :  work_dir:string
  -> verilog:string
  -> top_module:string
  -> ours:Circuit.t
  -> result

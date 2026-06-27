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

(** [check ~work_dir ~verilog ~renames ~top_module ~ours] proves [ours] sequentially
    equivalent to module [top_module] of file [verilog]. [ours] must be named distinctly
    from [top_module] (yosys reads both into one design), with its ports named to match.
    [renames] maps our register/net names to the reference's (applied to [ours] in yosys
    so [equiv_make] can pair the state); pass [[]] when the names already match (the
    iterative units, RS232T). *)
val check
  :  work_dir:string
  -> verilog:string
  -> renames:(string * string) list
  -> top_module:string
  -> ours:Circuit.t
  -> result

(** [check_shim] is the open-drain variant for the Mouse (AGENT.md §6, README Tier 2). The
    reference [MouseP] has bidirectional open-drain [inout msclk, msdat]; our gate splits
    each into a [*_oe] drive output + a resolved-value input. [shims] is a checked-in
    Verilog file with two wrappers — [gold_shim] (wraps [MouseP] from [verilog]) and
    [ours_shim] (wraps the emitted [ours]) — that both present one explicit interface: a
    {e free} external read input and the resolved open-drain line as the observable
    output. The flow flattens both shims, lowers all tristate to logic ([tribuf -formal] /
    [chformal -remove] / [setundef -one] — see the impl), renames the wrapped FFs to the
    RTL's (via [renames], stripping the instance prefix), and proves the two shims
    equivalent by [equiv_induct]. *)
val check_shim
  :  work_dir:string
  -> verilog:string
  -> shims:string
  -> gold_shim:string
  -> ours_shim:string
  -> renames:(string * string) list
  -> ours:Circuit.t
  -> result

(** [check_vid] is the partial multiclock variant for the video controller (AGENT.md §6,
    README Tier 2). VID is two-clock (pclk raster + clk DMA) and its framebuffer-fetch CDC
    deliberately departs from [VID60.v] (our toggle pulse-synchroniser vs the RTL's
    async-set [req1]), so a whole-VID equiv cannot close there. The flow proves AROUND the
    CDC: it drops [VID60.v]'s DCM/BUFG ([stubs] supplies their port shapes) and exposes
    [pclk] as a free clock to match ours, cuts [vidbuf] to a shared free input (so the
    pixel datapath proves bit-exact given the same fetched word), and excludes the [req]
    handshake output (the departure). What it proves: the raster + pixel datapath ≡
    [top_module]; the fetch CDC itself is argued separately (the cosim + [vid.ml]'s
    one-req-per-req0 invariant). *)
val check_vid
  :  work_dir:string
  -> verilog:string
  -> stubs:string
  -> top_module:string
  -> ours:Circuit.t
  -> result

(** [check_core] is the in-situ glue variant for the whole core (AGENT.md §6, README): it
    proves [ours] equivalent to [top_module] of [verilog] with the 8 submodules
    black-boxed. [stubs] is the port-only black-box module file both designs reference;
    [renames] maps our register names to the reference's (applied to [ours] so
    [equiv_make] pairs the flip-flops). The flow merges the matched black-box cells
    (checking their inputs) then [cutpoint -blackbox] turns their outputs into shared free
    signals — assume-guarantee, sound because each submodule is proven separately. *)
val check_core
  :  work_dir:string
  -> verilog:string
  -> stubs:string
  -> renames:(string * string) list
  -> top_module:string
  -> ours:Circuit.t
  -> result

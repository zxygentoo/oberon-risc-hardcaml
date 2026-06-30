(** Formal logic-equivalence of a Hardcaml circuit against its reference Verilog.

    The "Formal" layer of the verification pyramid (AGENT.md §6): where [test/cosim]
    {e simulates} a unit against its reference [.v] and compares samples, this {e proves}
    the two compute the identical function — exhaustively, via SAT, over every input.
    Combinational only ([hardcaml_verify]'s [Sec]: "stateful logic must be the same
    between the two circuits"), which is a complete proof for the datapath blocks
    (shifters, ALU logic/adder) and a deferred problem for the stateful units.

    Needs [yosys] (to import the Verilog) and [z3] ([Sec]'s SAT backend) on PATH. *)

open! Base
open Hardcaml

type result =
  | Equivalent (** proven: no input makes the outputs differ *)
  | Counterexample (** the SAT solver found differing inputs *)

(** [import ~work_dir ~verilog ~top_module] elaborates module [top_module] of file
    [verilog] into a Hardcaml circuit via [hardcaml_of_verilog] (yosys). [work_dir] holds
    the yosys scratch files (script + JSON netlist). *)
val import : work_dir:string -> verilog:string -> top_module:string -> Circuit.t

(** [check ~work_dir ~verilog ~top_module ~ours] proves [ours] computes the identical
    combinational function as module [top_module] of [verilog]. *)
val check
  :  work_dir:string
  -> verilog:string
  -> top_module:string
  -> ours:Circuit.t
  -> result

(** [check_circuits ~ours ~spec] proves [ours] computes the identical combinational
    function as [spec] — two in-process Hardcaml circuits, [Sec]-checked by z3 (no [.v]
    import). For a property checked against a spec written in Hardcaml rather than a
    reference [.v] (e.g. the VID look-ahead address ≡ a geometry spec). [ours] and [spec]
    must share port names. *)
val check_circuits : ours:Circuit.t -> spec:Circuit.t -> result

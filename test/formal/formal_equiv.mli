(** Combinational equivalence of a Hardcaml circuit and its reference Verilog.

    Where [test/cosim] simulates a unit against its [.v] and compares samples, this proves
    that the two compute the same function, over every input, by SAT. [hardcaml_verify]'s
    [Sec] requires the stateful logic of the two circuits to be the same, so this is a
    complete proof for the combinational blocks only; the units with state are proven by
    {!Yosys_equiv}.

    Needs [yosys] (to import the Verilog) and [z3] ([Sec]'s solver) on PATH. *)

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

(** [check_circuits ~ours ~spec] proves that [ours] computes the same combinational
    function as [spec], another Hardcaml circuit: for a property whose specification is
    written in Hardcaml because there is no [.v] to import (the video look-ahead address).
    The two must share port names. *)
val check_circuits : ours:Circuit.t -> spec:Circuit.t -> result

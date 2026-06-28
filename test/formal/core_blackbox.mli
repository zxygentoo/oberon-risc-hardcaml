(** The gate side of the in-situ core-glue proof: our {!Risc5.Risc5_core} assembled with
    the 8 submodules as black-box [Instantiation] stubs (module / instance / port /
    output-wire names matching [RISC5.v]), via {!Risc5.Risc5_core.create_with_units}.
    Proving this against [RISC5.v] with the units black-boxed checks the glue — decode,
    the inline ALU, control, flags, the 13 state registers — with the units
    assumed-equivalent (each proven separately, §6). See [proofs/core.ys.template] (run by
    {!Yosys_equiv.run_proof}) for the yosys flow and the README for the rationale. *)

open Hardcaml

(** the gate circuit, named [risc5_core_ours], ports named to match [RISC5.v]. *)
val circuit : unit -> Circuit.t

(** our 13 registers' names paired with [RISC5.v]'s, for the yosys [rename] that lets
    [equiv_make] pair the flip-flops ([irq1] already matches, so it is omitted). *)
val register_renames : (string * string) list

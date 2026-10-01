(** Our side of the core-glue proof: {!Risc5.Cpu} assembled, through
    {!Risc5.Cpu.create_with_units}, with the eight submodules as black-box [Instantiation]
    stubs whose module, instance, port and output-wire names are [RISC5.v]'s. Proving it
    against [RISC5.v], with the units black boxes there too, checks the glue — decode, the
    inline ALU, control, flags, the 13 state registers — on the assumption that the units
    are equivalent, which each unit's own proof discharges. The yosys flow is
    [proofs/core.ys.template]; the reasoning is in the README. *)

open Hardcaml

(** the gate circuit, named [risc5_core_ours], ports named to match [RISC5.v]. *)
val circuit : unit -> Circuit.t

(** our 13 registers' names paired with [RISC5.v]'s, for the yosys [rename] that lets
    [equiv_make] pair the flip-flops ([irq1] already matches, so it is omitted). *)
val register_renames : (string * string) list

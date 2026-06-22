(** Oberon RISC5 — Hardcaml design library.

    Curated index of the hardware modules, each a port of the corresponding Oberon Verilog
    source and verified in lockstep against the [risc_core] oracle. Modules land here one
    at a time from Phase 1 onward (shifters, ALU + flags, iterative MUL/DIV, the FP units,
    the register file, the CPU core, the SoC). *)

module Left_shifter = Left_shifter
module Fp_adder = Fp_adder
module Fp_multiplier = Fp_multiplier

(** The Oberon RISC5 machine as a Hardcaml library: the modules that consumers outside it
    reach — the test harnesses and the board layer.

    Most of them port one reference Verilog file each, named in the header of the .ml: the
    shifters, the multiplier and divider, the FP units, the register file, the core, and
    the peripherals. Two are compositions of this project's own: {!Peripherals}, the MMIO
    cluster both SoCs share, and {!Soc}, the simulation SoC over flat single-cycle RAM.
    The inline ALU and the simulation RAM are internal and are not exported. *)

module Left_shifter = Left_shifter
module Right_shifter = Right_shifter
module Registers = Registers
module Multiplier = Multiplier
module Divider = Divider
module Fp_adder = Fp_adder
module Fp_multiplier = Fp_multiplier
module Fp_divider = Fp_divider
module Cpu = Cpu
module Spi = Spi
module Uart_tx = Uart_tx
module Uart_rx = Uart_rx
module Ps2 = Ps2
module Video = Video
module Mouse = Mouse
module Rom = Rom
module Peripherals = Peripherals
module Soc = Soc

(** test scaffolding: the QCheck seed and corner-reaching generators *)
module Test_gen = Test_gen

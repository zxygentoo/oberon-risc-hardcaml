(** Oberon RISC5 — Hardcaml design library.

    Curated index of the machine's public modules — what the out-of-library consumers (the
    formal / co-sim / lockstep / boot-gate harnesses in test/, and the board layer)
    actually reach; internal-only blocks (the inline {b Alu}, the sim {b Ram}) stay
    unexported on purpose. Two kinds of module live here:

    - {b faithful unit ports} — each mirrors one reference Verilog file (named in its .ml
      header) and holds its green row in the AGENT.md §6 pyramid (formal equivalence, RTL
      co-sim, oracle lockstep): the shifters, MUL/DIV, the FP units, the register file,
      the CPU core, and the peripheral units;
    - {b own-design compositions} — {!Peripherals} (the RISC5Top MMIO cluster both SoCs
      share) and {!Soc} (the sim SoC over flat single-cycle RAM — the §6 verification
      vehicle), judged by the boot-level gates against the oracle, not against any single
      .v. *)

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

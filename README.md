# Oberon RISC5 → Hardcaml

A **cycle-accurate, synthesizable [Hardcaml](https://github.com/janestreet/hardcaml) port**
of Niklaus Wirth's **Project Oberon RISC5** machine — the OberonStation — targeting a
Digilent **Nexys 4** (Xilinx Artix-7 XC7A100T).

It boots **Project Oberon / Extended Oberon from SD card to the desktop on real
hardware**, as a standalone workstation: power-on QSPI boot, 60 MHz system clock (2.4× the
original), instruction/read cache + write buffer + BRAM framebuffer, VGA 1024×768,
3-button PS/2 mouse, USB keyboard, and a serial debug channel. It also runs
[DOOM](https://github.com/zxygentoo/DOOM-on-Oberon).

The port is built module-by-module from Wirth's original Verilog and verified against
**two oracles**: instruction-level lockstep against an
[OCaml emulator](https://github.com/zxygentoo/oberon-risc-emu-ocaml), and cycle-level
co-simulation plus **formal equivalence proofs** against the original RTL itself
(yosys `equiv_induct` / z3 — every datapath unit, the CPU core glue, and the peripherals
are *proven*, not just tested).

## Docs

- [`AGENT.md`](AGENT.md) — the working spec: architecture, the phase plan (0–10), and the
  verification strategy.
- [`boards/nexys-4/README.md`](boards/nexys-4/README.md) — the board layer: how the SoC
  maps onto the Nexys 4, and the build/program flow.

*This README is a placeholder — a proper write-up is coming. The project is under active
development.*

## License

[MIT](LICENSE)

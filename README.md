# Oberon RISC5 → Hardcaml

A **cycle-accurate, synthesizable [Hardcaml](https://github.com/janestreet/hardcaml) port**
of Niklaus Wirth's **Project Oberon RISC5** machine — the OberonStation — targeting a
Digilent **Nexys 4** (Xilinx Artix-7 XC7A100T).

It boots **Project Oberon / Extended Oberon from SD card to the desktop on real
hardware**, as a standalone workstation: power-on QSPI boot, 64 MHz system clock (2.56× the
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

- [`AGENTS.md`](AGENTS.md) — the working rules, for people and agents: what must not
  change, the layout, the gates, the conventions.
- [`docs/reference.md`](docs/reference.md) — the reference Verilog, the instruction set,
  the memory map, and where the emulator and the Verilog differ.
- [`docs/verification.md`](docs/verification.md) — the two oracles, the tests and proofs,
  the gates, and what they do not prove.
- [`build-log.md`](build-log.md) — the phase-by-phase build log (phases 0–11): what each
  phase delivered, how it was proven, and what was measured.
- [`board/nexys-4/README.md`](board/nexys-4/README.md) — the board layer: how the SoC
  maps onto the Nexys 4, and the build/program flow.

*This README is a placeholder — a proper write-up is coming. The project is under active
development.*

## Related repositories

- [`oberon-risc-emu-ocaml`](https://github.com/zxygentoo/oberon-risc-emu-ocaml) — the
  OCaml emulator, vendored here as a submodule: the oracle the port is checked against.
  It also hosts the host tools (`run_sim`, `run_dsk`, `script/mkdsk.sh`, and `oat`, the
  agent on the serial channel).
- [`oberon-risc-emu-rs`](https://github.com/zxygentoo/oberon-risc-emu-rs) — a Rust port
  of the emulator; its `DIVERGENCES.md` is the long record of where emulators and the
  Verilog differ.
- [`DOOM-on-Oberon`](https://github.com/zxygentoo/DOOM-on-Oberon) — the DOOM port that
  drove the display and performance work; its `ABI.md` specifies the Halftone interface.

## License

[MIT](LICENSE)

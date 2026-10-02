# Oberon RISC5 in Hardcaml

A cycle-accurate, synthesizable [Hardcaml](https://github.com/janestreet/hardcaml) port
of Niklaus Wirth's **Project Oberon RISC5** machine — the OberonStation — running on a
Digilent **Nexys 4** (Xilinx Artix-7 XC7A100T).

It boots Project Oberon and Extended Oberon from an SD card to the desktop on real
hardware, as a standalone workstation, and it runs
[DOOM](https://github.com/zxygentoo/DOOM-on-Oberon).

The port was built one module at a time from Wirth's Verilog, and it is held to two
references: an [OCaml emulator](https://github.com/zxygentoo/oberon-risc-emu-ocaml) for
what each instruction computes, and the original Verilog itself, by co-simulation and by
equivalence proofs, for what each register does on each clock.

## The machine

- **The faithful port** (`lib/`): the RISC5 core, its multiplier, divider, shifters and
  floating-point units, the register file, UART, SPI, PS/2 keyboard and mouse, and the
  video controller. Each mirrors its Verilog original register for register.
- **The board layer** (`board/nexys-4/`): what a Nexys 4 needs that the original
  OberonStation did not. Main memory is a 16 MiB PSRAM that takes five or six clocks
  per halfword, so the layer adds an instruction and data cache, a write buffer and a
  framebuffer copy in block RAM, and it freezes the core while memory is busy. It also
  adds Halftone, an 8-bit display mode dithered onto the 1-bit screen.
- **As shipped:** a 64 MHz system clock (the original runs at 25), VGA at 1024 × 768,
  a 3-button PS/2 mouse, a USB keyboard, a serial line at 115200 baud, and power-on boot
  from the QSPI flash. It uses 6,524 LUTs (10%), 51 block RAM tiles (38%) and 6 DSP
  slices of the XC7A100T.

## How it is checked

| Against | What | How |
|---|---|---|
| the emulator | every instruction class, and short programs | 290,000 random cases, the state compared after each instruction |
| the emulator | a whole boot | the state at the jump into the OS, then the desktop's framebuffer, byte for byte; on the simulation SoC and on the board SoC as shipped |
| the Verilog | nine units, and the core over 10 M cycles of a boot | co-simulation under Verilator, every output on every cycle |
| the Verilog | twelve units and the core's glue | equivalence proofs (yosys induction, z3) |
| a specification | the register file, the video look-ahead, the video clock crossing | proofs |
| the hardware | the board | it boots, rebuilds the whole Oberon system without a trap, and plays DOOM's timedemo to the exact tick count |

The proofs are of the default machine. The parts of the shipped board that depart from
the original — the caches, the DSP multipliers, the clock enable — are checked by
simulation against the emulator, not proven.
[`docs/verification.md`](docs/verification.md) has the detail, including what the gates
do not prove.

## How fast

With memory behind the PSRAM alone, the running OS costs 27.8 clocks per instruction.
The shipped machine costs **1.30**, with 1.6% of its clocks spent waiting on memory:

| | Clocks per instruction | Clocks waiting on memory |
|---|---|---|
| PSRAM alone | 27.80 | 94.8% |
| + a 16 KiB cache | 1.77 | 27.5% |
| + stores update the cache | 1.50 | 14.5% |
| + the framebuffer in block RAM | 1.44 | 11.1% |
| + a write buffer | 1.34 | 4.5% |
| + a second entry in it | **1.30** | 1.6% |

Each layer was priced by running the same instructions with and without it
([`test/bench/README.md`](test/bench/README.md)); the story of the measurements is in
[`build-log.md`](build-log.md). DOOM's timedemo runs at 15 frames a second.

## Getting started

The toolchain is [OxCaml](https://oxcaml.org) with the Hardcaml `v0.18~preview` that
its opam repository carries.

```sh
git clone --recurse-submodules https://github.com/zxygentoo/oberon-risc-hardcaml.git
cd oberon-risc-hardcaml

opam switch create 5.2.0+ox \
  --repos ox=git+https://github.com/oxcaml/opam-repository.git,default
eval $(opam env --switch 5.2.0+ox --set-switch)
opam install hardcaml hardcaml_waveterm ppx_hardcaml ppx_expect qcheck-core \
             hardcaml_verify hardcaml_of_verilog ocamlformat

dune build @check     # type-check everything
dune runtest          # unit tests, FP replays, the lockstep: about 15 s
```

The heavier gates are opt-in:

```sh
dune build @boot_checkpoint       # boot the real disk image to the OS handoff
dune build @visual_golden         # ... and on to the desktop
dune build @cosim                 # co-simulation against the Verilog   (needs verilator)
dune build @formal                # the 17 proofs                       (needs yosys, z3)
dune build @gates                 # everything, about 10 minutes
```

The reference Verilog is not in the repository (it is not ours to redistribute). The
co-simulation and the proofs fetch it on first use and verify it against pinned
checksums.

## On a board

You need a Nexys 4 (the original, with cellular RAM, not the Nexys 4 DDR), a VGA monitor,
a PS/2 mouse on a Pmod PS/2 in the top row of JA, a plain USB keyboard, and a microSD
card. Vivado builds the bitstream (2025.2 is what we use):

```sh
board/nexys-4/gen_verilog.sh                          # the SoC as Verilog
vivado -mode batch -source board/nexys-4/build.tcl    # synthesize, place, route
vivado -mode batch -source board/nexys-4/program.tcl  # load over JTAG, or
vivado -mode batch -source board/nexys-4/flash.tcl    # write the QSPI flash
```

The SD card holds the Oberon file system where the OberonStation expects it, 0x80002
blocks in. A `.dsk` image, as the emulators use, is the file system alone, so it goes at
that offset (the image in `vendor/oberon-risc-emu-ocaml/DiskImage/` is the one the gates
boot):

```sh
dd if=Oberon-2020-08-18.dsk of=/dev/sdX bs=512 seek=524290 conv=notrunc
```

[`board/nexys-4/README.md`](board/nexys-4/README.md) covers the board in detail: the
memory stack, the clocks, the PS/2 wiring and its pitfalls.

## Documents

- [`AGENTS.md`](AGENTS.md) — the working rules, for people and agents: what must not
  change, the layout, the gates, the conventions.
- [`docs/reference.md`](docs/reference.md) — the reference Verilog, the instruction set,
  the memory map, and where the emulator and the Verilog differ.
- [`docs/verification.md`](docs/verification.md) — the two oracles, the tests and proofs,
  the gates, and what they do not prove.
- [`board/nexys-4/README.md`](board/nexys-4/README.md) — the board layer and the Vivado
  flow.
- [`test/formal/README.md`](test/formal/README.md),
  [`test/cosim/README.md`](test/cosim/README.md),
  [`test/bench/README.md`](test/bench/README.md) — the proofs, the co-simulation, the
  gauges.
- [`build-log.md`](build-log.md) — how it was built, phase by phase: what each phase
  delivered, how it was checked, what was measured.

## Related repositories

- [`oberon-risc-emu-ocaml`](https://github.com/zxygentoo/oberon-risc-emu-ocaml) — the
  OCaml emulator, vendored here as a submodule: the oracle the port is checked against.
  It also hosts `oat`, the tool that talks to a running Oberon over the serial line.
- [`oberon-risc-emu-rs`](https://github.com/zxygentoo/oberon-risc-emu-rs) — a Rust port
  of the emulator; its `DIVERGENCES.md` is the long record of where emulators and the
  Verilog differ.
- [`DOOM-on-Oberon`](https://github.com/zxygentoo/DOOM-on-Oberon) — the DOOM port that
  drove the display and performance work; its `ABI.md` specifies the Halftone interface.

## Credits

Project Oberon, its RISC5 processor and the OberonStation's Verilog are the work of
Niklaus Wirth, Jürg Gutknecht and Paul Reed ([projectoberon.net](http://www.projectoberon.net)).
The emulators descend from Peter De Wachter's
[oberon-risc-emu](https://github.com/pdewacht/oberon-risc-emu). Extended Oberon is
Andreas Pirklbauer's.

## License

[MIT](LICENSE), for the code in this repository. The reference Verilog and the Oberon
system are their authors'.

# Oberon RISC5 in Hardcaml — working rules

A cycle-accurate, synthesizable Hardcaml port of Niklaus Wirth's Project Oberon RISC5
machine, running on a Digilent Nexys 4. `lib/` is proven equivalent to the original
Verilog, and the whole machine is checked against an OCaml emulator. This file holds what
you must know before changing anything; the rest is reference:

| Read | For |
|---|---|
| `README.md` | what the machine is; how to build, program and run it |
| `docs/reference.md` | the ISA, the reference Verilog file by file, the emulator-vs-RTL divergences |
| `docs/verification.md` | the two oracles; what each gate proves and what it does not |
| `board/nexys-4/README.md` | the board: PSRAM, cache, clocks, PS/2, the Vivado flow |
| `test/{formal,cosim,bench}/README.md` | the proofs, the co-simulation, the gauges |
| `build-log.md` | how it was built: phases, measurements, dead ends |

## Rules

1. **`lib/` is the faithful port, and the Verilog's behaviour is the spec.** Mirror the
   RTL's sequential skeleton exactly: which signals are registered, stall and
   state-counter timing (MUL/DIV's 33 cycles), interrupt timing. Write the combinational
   datapath as idiomatic Hardcaml; only its truth table is observable. Register names are
   fixed: the lockstep and the yosys proofs reach state by name.
2. **Departures belong to the board layer.** Caches, the write buffer, the shadows,
   Halftone, and the default-off seams inside `lib/` (`?multipliers`, `?baud_*`) are
   judged against the ISA and the emulator, not against RTL timing. The default `lib/`
   machine stays as it is; never trade it for speed.
3. **Where the emulator and `RISC5.v` disagree, the port follows `RISC5.v`.** The known
   cases are in `docs/reference.md`, and the lockstep steers around them. A new one goes
   on that list.
4. **Done means the gate is green.** A change to `lib/` keeps `@cosim` and `@formal`
   green, and a new faithful unit gets a proof row. A change to the board layer passes
   the board gates, shows a same-work comparison (`@bench_boot`), and ends with a boot on
   hardware.
5. **Measure, don't guess.** Performance claims come from the gauges
   (`test/bench/README.md`), before and after, over the same work.
6. **Everything synthesizes, and a refactor does not change the netlist.** Hash the
   output of `board/nexys-4/emit_verilog.exe` before and after.
7. **The shipped machine is defined once,** in `board/nexys-4/build_config.ml`. Its test
   checks `nexys4_top.v` and `nexys4.xdc` against it: a clock or timing change touches
   all three.

## Layout

- `lib/` (library `risc5`): the core (`cpu.ml`, a port of `RISC5.v`), the datapath
  units, the peripherals, the boot ROM, and a SoC over a flat 1 MB RAM, which the
  verification runs on.
- `board/nexys-4/` (library `nexys4_board`): the real-memory SoC — `cellram` (PSRAM
  controller, arbiter, write buffer), `cache`, `framebuf`, `halftone`, `soc`,
  `build_config`, `emit_verilog` — and the test-only `cellram_model`. It depends on
  `risc5`, never the reverse. `nexys4_top.v` and `nexys4.xdc` are the only vendor code.
- `test/`: the fast suite at the top; `boot/` (the boot harness and the sim-SoC gates),
  `board/nexys-4/` (the board gates and the board gauge), `cosim/`, `formal/`, `bench/`.
- `vendor/`: the emulator, a submodule built as library `emu`. Never edit it from here.
- Git-ignored: `board/_generated/`, `board/_build/`, `test/_work/`, and `test/_po/` —
  the reference Verilog, fetched by `test/fetch-rtl.sh` and checksum-pinned in
  `test/rtl-sources.txt`. It is not ours to redistribute, and changing a pin is deliberate.

## Gates

| Gate | Checks | Time, needs |
|---|---|---|
| `dune build @check` | everything type-checks (it does not link the gate executables) | seconds |
| `dune runtest` | unit tests, FP replays, single-instruction lockstep, ROM guard | 15 s |
| `@boot_checkpoint` | the sim SoC boots the real disk to the OS handoff; state = emulator's | 25 s |
| `@visual_golden` | on to the idle desktop; framebuffer and scan-out pixel-exact | 2 min |
| `@boot_checkpoint_board`, `@visual_golden_board` | the same through the board SoC as shipped | 4 + 10 min |
| `@cosim` | each unit, and the core over a boot, cycle-exact against the Verilog | 1 min; verilator |
| `@formal` | the 17 equivalence and property proofs | 15 s; yosys, z3 |
| `@gates` | all of the above | 10 min |
| `@bench`, `@profile_boot`, `@bench_boot` | gauges: reports, not verdicts | |

`SPI_DIV_LOG2=2` makes any boot gate 2–4× faster with the same end state. The board gates
take environment knobs that switch features off for bisecting (`board_tb.mli`).

## Conventions

- **Toolchain.** opam switch `5.2.0+ox`: `eval $(opam env --switch 5.2.0+ox
  --set-switch)` first. Hardcaml is `v0.18~preview`, and `docs.hardcaml.org` documents
  exactly that API; examples elsewhere are often v0.17 (ours: `sll x ~by:n`,
  `select x ~high ~low`, `uresize x ~width`, `to_unsigned_int`, `of_unsigned_int ~width`).
- **Modules.** Named by role (`cpu.ml`, `uart_rx.ml`), not after the Verilog files.
  Every design module has an `.mli`, which owns the contract; a faithful module's `.ml`
  header names the RTL file it ports. `lib/left_shifter.{ml,mli}` is the reference shape.
- **Library.** `Base` over `Stdlib`, opened with `open!`; `==:` for signals, typed
  equality for OCaml values.
- **Tests.** A module's tests sit in its `.ml`: `ppx_expect`, and QCheck (through
  `Test_gen.check_exn`) for anything random. `test/` is for what needs the emulator or a
  whole system. Waveform expects pin `~wave_width:4` and a `~display_width`. Build the
  simulator once, outside the property.
- **Comments.** Say why: the hazard, the invariant, where the structure mirrors the RTL.
  No history, no branch or phase names, no measurement stories (those go to
  `build-log.md`), no section references into documents.
- **Format.** `dune fmt`; `.ocamlformat` has no version pin, on purpose. ocamlformat
  mangles multi-line Verilog and brace literals inside comments: use prose.
- **Git.** Work on `develop`, features on `feat/<name>`, never commit to `main`. Before
  each commit run `dune fmt` and `dune build @check` and fix what they flag; if a fix is
  not reasonable, stop and ask instead of suppressing it. An agent ends its commit
  messages with its `Co-Authored-By:` trailer.

## Traps

- `&:` and `|:` have equal precedence, left to right: parenthesize mixed logic.
- A port named `rst`, `reset` or `clear` traces as constant 0 in waveforms: use `rst_n`.
- `open Hardcaml` shadows the sibling modules `Ram` and `Rom` inside `lib/`: bind them
  before the opens (`lib/soc.ml`).
- Cyclesim: registers need `lookup_reg_by_name`. Use `lookup_node_or_reg_by_name` and
  fail on `None`, or a missing probe reads as zeros.
- Cyclesim prunes logic that reaches no output: keep the observed path live.
- `Cyclesim.outputs` samples after the edge by default; input-driven pulses show only
  with `~clock_edge:Before`. Asynchronous memory reads settle after the edge.
- Cyclesim has one clock domain: pclk logic advances with `clk` whatever the pclk input
  does. `By_input_clocks` gives real multi-clock; waveforms are unreliable across domains.
- Two version shims, explained where they live: `-source-tree-root .` in each
  inline-tests `dune` file, and `write_json -compat-int` in `test/formal/formal_equiv.ml`.

## Settled — bring new evidence before reopening

- Compiled simulation backends (`hardcaml_c`, `hardcaml_verilator`) and
  `hardcaml_step_testbench`: rejected; the gates run the plain interpreter.
- PSRAM: `write_cycles` stays 5, a documented deviation from the datasheet; the other
  latency levers are priced below noise (`build-log.md`).
- Cache and clock: 16 KiB is the knee, and 65 MHz needs a seventh read clock.

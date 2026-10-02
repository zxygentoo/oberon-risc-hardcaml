# Verification

How the port is checked: the two things it is checked against, the layers of tests and
proofs, the gates that run them, and what they leave unproven.

## Two oracles

The port is held to two references, and they answer different questions.

**The emulator** (`vendor/`, built in-process as library `emu`) answers *is the result
right?* It gives the architectural state — `pc`, the registers, `H`, the flags, memory —
after each instruction. It knows nothing of wires or cycles; its millisecond clock is
injected.

**The original Verilog** answers *did we copy the machine?* Under Verilator
(`test/cosim/`) it gives any signal on any cycle, and under yosys and z3 (`test/formal/`)
it is the other side of an equivalence proof.

The two also check each other. Every known difference between them
([reference.md](reference.md)) is the emulator departing from `RISC5.v`, and in each the
co-simulation shows the port on the Verilog's side.

## What cycle fidelity buys

The emulator works at the level of instructions; it would pass a multiplier that took one
cycle just as it passes one that takes 33. So why mirror the Verilog's timing?

- The equivalence proofs become possible: the same registers, changing on the same
  cycles, can be paired flip-flop by flip-flop and proven equal for all inputs.
- `RISC5.v` becomes a debugging oracle at the level of cycles: run both on the same
  inputs, and the first cycle that differs is the bug.
- There is a bright line. A port that matches the RTL exactly needs no argument, for each
  deviation, that the deviation is harmless.

That is why departures from the Verilog's timing live in the board layer and behind
default-off parameters, and why the default `lib/` machine never changes.

## The layers

1. **Unit tests**, in each design module's `.ml`: exhaustive or QCheck properties for
   the combinational blocks, frozen waveforms for the multi-cycle units.
2. **Floating-point vectors.** The emulator's frozen vectors are replayed through the
   three FP units (2,576 each for multiply and divide; for the adder the 1,624 forms the
   compiler can emit), and each unit is fuzzed against the emulator's FP routines.
3. **Co-simulation against the Verilog** (`@cosim`). For each of nine units — the three
   FP units, SPI, the UART in both directions, the PS/2 keyboard, the mouse, video — a
   dumper drives the Hardcaml port over a set of stimuli and records what it saw; a C++
   harness replays the stimuli through the reference `.v` under Verilator and requires
   the same values on the same cycles. The tenth unit is the core: its inputs and outputs
   are recorded on every cycle of a real boot (10 M cycles: the boot loader, the handoff,
   then the OS starting up) and replayed through `RISC5.v`. The first cycle that differs
   is reported.
4. **Single-instruction lockstep** (`test/test_cpu_lockstep.ml`). Random instructions
   are driven into the core, and the architectural state afterwards is compared with the
   emulator's: 50,000 cases each of register operations, branches, loads and stores, then
   20,000 short programs run from RAM under a random external stall. The register
   operations and the programs run again with the DSP multipliers. The emulator has no
   interrupts, so the interrupt logic is not covered here: a waveform test and the core
   proof cover it.
5. **Boots.** A booting machine cannot be compared with the emulator instruction by
   instruction: code addresses differ while the ROM runs, the emulator takes no
   interrupts, and the millisecond clock and the SD card are polled at different moments.
   None of that changes where the boot ends up, so boots are compared by end state, on
   the same disk image:
   - the **handoff checkpoint**: run to the jump into the OS (`pc = 0`, 403,030
     instructions) and compare the architectural state and the loaded image, 131,072
     words. One register and seven stack words differ by the ROM's address offset, and
     nothing else may;
   - the **visual golden**: run on to the idle desktop and require the framebuffer
     identical byte for byte (hash `0xb9bdbf56ba51298d`, 18,607 pixels lit). Then one
     more frame is read off the `rgb` pins, and it must reproduce the framebuffer.

   Both exist for the simulation SoC and for the board SoC. The board gates boot the
   configuration that ships (`Build_config.shipped`, the value the emitter uses) against
   a model of the PSRAM chip held to its datasheet; with the framebuffer shadow, the
   golden also requires the shadow to equal the PSRAM's copy.
6. **Proofs** (`@formal`), 17 of them. The inventory, and how each is built, is in
   `test/formal/README.md`:
   - the two shifters: the `.v` is imported and proven equal as a function, by z3;
   - the multiplier, the divider, the three FP units, the two UART directions, SPI and
     the PS/2 keyboard: our emitted Verilog against the `.v` inside yosys, flip-flops
     paired by name, the step proven by induction. This is why `lib/` registers carry the
     RTL's names;
   - the register file, against a written specification (`Registers.v` is built from
     64 RAM primitives whose state cannot be paired with an array's);
   - the core's glue — decode, the ALU, control, flags, the state registers — against
     `RISC5.v`, with the eight units as black boxes on both sides;
   - the mouse, through a shim that turns its open-drain lines into plain logic;
   - video in three parts: the raster and the pixel path against `VID60.v`; the
     fetch-request synchroniser as a property (one request out for each one in); the
     look-ahead address against a written specification.

For changes to the board layer there is one more instrument: the **same-work
comparison** (`@bench_boot`). Two configurations run the same instructions, aligned by
`pc`, and their clocks are compared. It is how each layer of the memory stack was priced
(`test/bench/README.md`).

## The gates

`dune build @check` type-checks everything, the gates included, so none of them can rot
unnoticed. It does not link their executables: `dune exec`, or build the `.exe`, before
running one by hand.

| Gate | What runs | Time | Needs |
|---|---|---|---|
| `dune runtest` | layers 1, 2 and 4, and a guard that the design and the emulator boot the same ROM | 15 s | |
| `@boot_checkpoint` | the simulation SoC to the handoff | 25 s | |
| `@visual_golden` | the simulation SoC to the desktop, and the scan-out | 2 min | |
| `@boot_checkpoint_board` | the board SoC to the handoff, twice: the bare PSRAM controller, then as shipped | 4 min | |
| `@visual_golden_board` | the board SoC as shipped to the desktop, and the scan-out | 10 min | |
| `@cosim` | layer 3 | 1 min | verilator |
| `@formal` | layer 6 | 15 s | yosys, z3 |
| `@gates` | all of the above | 10 min | all three |
| `@bench`, `@profile_boot`, `@bench_boot` | the gauges: reports, not verdicts | to 4 min | |

Things to know when running them:

- **Fast boots.** `SPI_DIV_LOG2=2` gives the SPI master a fast divider. A boot spends
  most of its clocks waiting for the SD card, so every boot gate runs two to four times
  faster, to the same end state. Leave it off for the run before a commit.
- **Bisecting on the board.** The board gates read environment knobs that switch
  features off or retune them: `ICACHE`, `WRITE_UPDATE`, `FB_BRAM`, `HALFTONE`,
  `FAST_MUL`, `MUL_STAGES`, `LINES_LOG2`, `WBUF`, `READ_CYCLES`, `WRITE_CYCLES`
  (`test/board/nexys-4/board_tb.mli`). An unparsable value fails loudly.
- **Reproducing a property failure.** QCheck runs under a fixed seed; `QCHECK_SEED`
  overrides it.
- **One unit.** `dune exec test/cosim/cosim_run.exe -- <unit>` and
  `dune exec test/formal/formal_run.exe -- <check>` run a single one with its output on
  the terminal.
- **The simulator** is the plain Cyclesim interpreter, about 0.4 M cycles a second on
  the simulation SoC.

## What the gates do not prove

- **The proofs are of the step.** yosys proves that from any common state the two
  designs take the same step. It does not start from reset, and it does not check which
  clock a register is on; the co-simulation and the boots cover both.
- **The proofs are of the default machine.** The clock enable, the DSP multipliers, and
  the retuned UART and SPI dividers of the shipped board are checked by simulation: the
  lockstep with the DSP multipliers, the board gates. They are not proven.
- **Two proofs are against specifications written here**, not against Wirth's Verilog:
  the register file and the video look-ahead address.
- **Video is proven around its two departures.** The step that joins the three video
  proofs is an argument by hand (`test/formal/README.md`, "VID prefetch"), checked by a
  simulation test. The synchroniser's property is proven for a request every 8 pixel
  clocks and clocks within 2:1 of each other; the machine's own spacing is 32 at 65:25.
- **Each proof was checked against a seeded bug once**, by hand, when it was written.
  `@formal` re-runs the proofs, not the mutations.
- **Video's co-simulation** feeds both sides an 18-bit address as the framebuffer word,
  so the upper 14 bits of a fetched word are zero there. The visual goldens are what
  carry real pixels through all 32.
- **The SD card model** reads the SPI master's shift register by name, not the `mosi`
  pin. The pin is checked by SPI's co-simulation and its proof.
- **The emulator has no interrupts**, so no boot compares interrupt behaviour with it.
- **The handoff checkpoint** compares the loaded image, the lower 512 KB.
- **The shipped UART divisors and the PSRAM's pin timing** are not simulated at their
  real rates. The chip model enforces the datasheet by counting clocks; the nanoseconds
  are the timing constraints' and the hardware's job.

So the last gate for a change to the board layer is a boot on the board.

## Writing tests

- **A module's tests live in its `.ml`**, as `ppx_expect` tests. `test/` is for tests
  that need the emulator (the design library must never depend on it) and for whole
  systems. The test tooling (`hardcaml_waveterm`, `qcheck-core`) sits in the library's
  own `(libraries)` and never reaches the generated Verilog.
- **Anything random is a QCheck property**, run through `Risc5.Test_gen.check_exn`.
  Build the simulator once, outside the property: rebuilding a 1 MB RAM for every case
  once cost 47 s of `dune runtest`.
- **Waveform tests are for multi-cycle timing.** Pin the rendering — `~wave_width:4`,
  the least that still shows 32-bit hex, and an explicit `~display_width` — or an update
  of the library reflows the frozen picture. `lib/left_shifter.ml` is the reference
  shape. `dune promote` accepts a new one.
- **A check that cannot fail proves nothing.** Try a new test or proof once against a
  seeded bug.

Cyclesim has traps, and each has cost a debugging session:

- **Registers are not nodes.** `lookup_node_by_name` does not find a register; a lookup
  that defaults on `None` then reads as zeros. Use `lookup_node_or_reg_by_name`, and
  fail when a probe that must exist does not.
- **Logic that reaches no output is pruned.** The framebuffer shadow's RAMs once vanished
  from a simulation because only `sclk` was observed. Keep the path you care about live:
  the board test bench carries `hsync`, `vsync` and `rgb` for this.
- **Outputs are sampled after the clock edge by default**, where a pulse driven by an
  input no longer shows. Sample with `~clock_edge:Before` to see what the core saw.
- **Asynchronous memory reads settle after the edge.** Assert on them after a full
  cycle, not before the edge.
- **There is one clock domain.** Logic on `pclk` advances with `clk`, whatever the
  `pclk` input does, so the video DMA is live in every board simulation: an honest
  comparison takes it off the PSRAM port by configuration (`fb_bram`). `By_input_clocks`
  gives real multi-clock simulation. Reset is sampled on an edge, so an asynchronous set
  has to be modelled. Waveforms are unreliable across domains: print a table.
- **A port named `rst`, `reset` or `clear`** traces as constant 0 in a waveform, though
  the logic is right. Name it `rst_n`.

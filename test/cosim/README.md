# `test/cosim` — co-simulation against the reference Verilog

Checks that a Hardcaml unit matches Wirth's Verilog in both value and timing: the
reference `.v` runs under **Verilator**, and its outputs are compared with the port's,
cycle for cycle. This is the *fidelity* check — did we copy the machine? — as distinct
from the emulator, which checks results. [`test/formal`](../formal) proves the same
comparison for all inputs; this samples it, and unlike the proofs it starts from reset
and runs real clocks.

It is opt-in, not part of `dune runtest`, and needs `verilator` on `PATH`.

The reference Verilog is not in the repository. The runner fetches it on first use into
`test/_po/` and verifies it against `test/rtl-sources.txt` (see "The reference Verilog"
below).

## Running

```sh
dune build @cosim                              # all ten units in parallel, with a PASS/FAIL summary
dune exec test/cosim/cosim_run.exe -- vid      # one unit, output on the terminal: fp_adder |
                                               #   fp_multiplier | fp_divider | spi | rs232t |
                                               #   rs232r | ps2 | vid | mouse | core
dune exec test/cosim/cosim_run.exe -- all 4    # all, at most 4 at a time
```

dune caches the alias; re-run with `--force`. The runner (`cosim_run.ml`) makes sure the
reference Verilog is there and the dumpers are built, then runs every unit in its own
forked worker, with the output in `test/_work/cosim/<unit>/run.log`. It prints a
PASS/FAIL table, the tail of any failing log, and exits nonzero if any unit failed. The
nine stimulus units take a few seconds each; the core takes about 45 s and sets the wall
time of a full run.

## The nine stimulus units

A dumper drives the Hardcaml port over a set of stimuli and records what it saw. A C++
harness replays the stimuli through the reference `.v` and requires the same values on
the same cycles.

- **The FP units** — the frozen vectors for the unit, and 20,000 random operands. The
  result and the length of the stall must both match.
- **SPI** — corner words at both rates and about 640 random transfers, each with its own
  recorded MISO stream. `rdy`, `sclk` and `mosi` are compared every cycle, then the
  received data and the length of the transfer.
- **UART transmit** — corner bytes at both rates and about 72 random frames. `rdy` and
  `TxD` every cycle, and the frame's length.
- **UART receive** — the dumper plays the sender, driving a frame on `RxD` and then the
  acknowledge; about 36 random frames. `rdy` every cycle, and the data whenever `rdy` is
  high.
- **PS/2 keyboard** — the dumper plays the keyboard, clocking 11-bit frames in and
  popping the byte; about 48 frames. `rdy` every cycle, and the data when `rdy`. The
  order of several queued bytes is checked by the unit's own test.
- **PS/2 mouse** — the lines are open-drain and bidirectional (`inout` in the RTL). A
  wrapper (`mouse_cosim.v`) splits each line as the Hardcaml port does: it forces the
  resolved value into the design and reads the design's own pull-low back out. The
  dumper plays a mouse through the initialisation handshake and four movement reports
  (both signs, buttons, overflow). All outputs are compared every cycle, over about
  505,000 cycles.
- **Video** — two clocks, the system clock and the pixel clock, at 25:65. A wrapper
  (`vid_cosim.v`) stubs the Xilinx clock primitives and forces the pixel clock from the
  harness, which drives both clocks at the dumper's cadence. About three scan lines and
  a toggle of `inv` are replayed; `hsync`, `vsync` and `RGB` are compared on every tick.

Video's two deliberate departures from `VID60.v` (see `lib/video.ml`) are handled so:

- **`req`**, the fetch request, crosses clock domains through our synchroniser about two
  clocks later than `VID60.v`'s asynchronous set. Its timing cannot match, so the two
  sides must only produce the same *number* of requests (within one, for a request in
  flight at the end). That exactly one request comes out for each one in is proven in
  `test/formal` (`vid_invariant`).
- **`vidadr`**: our look-ahead asks for each word one group early, so the address leads
  `VID60.v`'s by one column. It is not compared. That the look-ahead delivers the right
  word is the business of a test in `lib/video.ml` and of `test/formal`.

Because the two addresses differ on every tick, no single replayed stream of framebuffer
data could be right for both sides. So **each side's memory echoes its own address**:
the dumper drives our `viddata` with our `vidadr`, and the harness drives `VID60.v`'s
with `VID60.v`'s. The address is steady across a group, so each side samples the word it
asked for, and both display the same picture. Two consequences: `RGB` is compared from
the second scan line on (the look-ahead has not yet fetched the first group of the first
line), and the framebuffer word is an 18-bit address, so the upper 14 bits of a fetched
word are zero in this check. Vertical blanking and sync would need a whole frame; the
visual goldens cover them, with real pixels.

A stimulus harness compares whatever its dumper produced, and its log prints how many
stimuli that was. It does not itself reject an empty dump.

## The core

The tenth unit has another shape: **a real boot, replayed**. `core_dump.ml` boots the
simulation SoC from the real disk image and records the core's inputs (`rst`, `irq`,
`stallX`, `codebus`, `inbus`) and outputs (`adr`, `rd`, `wr`, `ben`, `outbus`) on every
cycle. `core.cpp` runs `RISC5.v` and its eight units under Verilator, drives them with
the recorded inputs, and requires the recorded outputs on every cycle. It reports the
first cycle that differs.

By default the trace is 10 M cycles, captured with the fast SPI divider (the check is of
the core, not of SPI): reset, the boot loader reading the SD card, the handoff to the OS
at about 1.9 M cycles, then some 8 M cycles of compiled Oberon. The boot loader alone
uses only MOV, ADD, SUB, word loads and stores, and branches. Byte accesses, DIV, MUL
and the shifts first appear after the handoff, which is why the capture must get there.
Not covered: interrupts (Oberon never enables them) and the FP instructions (rare in a
boot). `CAP` sets the length.

**Why the first mismatch is exactly the bug.** Both cores start from the same reset
state. For as long as our outputs equal `RISC5.v`'s, memory evolves identically on both
sides, and with it the inputs, which are functions of memory. So the comparison is valid
up to the first cycle on which our core does something `RISC5.v` would not, and that
cycle is a minimal reproducer. This is how a real bug was found: a branch whose op field
read as ADD clobbered the carry flag while it was stalled, 7.7 M cycles into a boot.

The trace is captured afresh on every run (about 160 MiB in `test/_work/cosim/core`). It
is the port's own recorded behaviour, and a reused trace would vouch for a core that has
since changed. Each record holds the inputs a state consumes and the outputs it drives,
taken before the clock edge, which keeps the trace consistent across the release of
reset. `CYC_FROM`, `CYC_TO` and `NOTRACE` make `core_dump` print `pc`, `ir`, the flags
and the registers over a window, for looking closely at a mismatch.

## The reference Verilog

`test/fetch-rtl.sh`, shared with the proofs, fills `test/_po/verilog/src/` on demand. If
the pinned files are there and match, it does nothing. Otherwise it downloads
`OStationVerilog.zip`, verifies the archive's SHA-256, extracts `src/*.v`, and verifies
each file against `test/rtl-sources.txt` before anything uses it. A mismatch means
upstream has moved from the revision the port was verified against, and the run refuses
to compare with unknown Verilog. Moving to a newer revision is a deliberate edit of
`rtl-sources.txt`. Without a network: download the archive yourself and unzip its
`src/*.v` into `test/_po/verilog/src/`.

## The files

| File | Role |
|---|---|
| `<unit>_dump.ml` | a dumper: drives the Hardcaml port and writes a trace. `fp_dump` serves the three FP units and `rs232_dump` both UART directions; the others are one per unit |
| `cosim_dump.ml` | helpers the dumpers share |
| `<unit>.cpp` | the Verilator harness for a unit. The FP ones are a few lines; the serial ones a reset and a replay; `vid` (two clocks) and `mouse` (open drain) have their own `main` |
| `cosim.h` | what the harnesses share: opening the dump, the clock tick, and two runners — one for the stall-based FP units, one for the cycle-by-cycle serial units |
| `vid_cosim.v`, `mouse_cosim.v` | the wrappers Verilator gets beside the reference `.v` |
| `ram16x1d.v` | the `RAM16X1D` primitive that `Registers.v` uses, for the core replay |
| `core_dump.ml`, `core.cpp` | the core's capture and replay |
| `cosim_run.ml` | the runner: fetch, build, then per unit dump → verilate → compare, in a pool of workers |

The dumpers are built by `dune build @check`, without Verilator, so they cannot rot
unnoticed.

## Adding a unit

Every unit is one entry in `cosim_run.ml`'s `units` list.

**A unit with the `run` / `stall` / `z` protocol** reuses `fp_dump`:

1. a `*_driver ()` in `fp_dump.ml` that builds the simulator and sets the inputs, and an
   arm in its match on the unit's name (the run-and-drain loop is shared);
2. a `<unit>.cpp` of a few lines that names the unit and passes `parse_xy` (or
   `parse_xyuv`, if it carries `u` and `v`) to `run_drain_cosim`;
3. a `Stimulus` entry with `fp_dump` as its dumper.

**Any other interface** gets its own `<unit>_dump.ml` and `<unit>.cpp`. `spi_dump.ml`
and `spi.cpp` are the pattern: dump a trace with one record per cycle (the stimulus and
the outputs to check), and let the harness run the RTL to its own end condition while
comparing every cycle.

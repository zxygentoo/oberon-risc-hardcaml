# test/cosim — RTL-fidelity co-simulation (opt-in)

Confirms a Hardcaml design is **bit-exact to Wirth's original Verilog** — in both result
*and* timing — by driving the reference RTL through **Verilator** and comparing each
stimulus's output `z` and its stall length against the Hardcaml port. This is the
simulation-based preview of the Phase-8 formal-equivalence proof
(`hardcaml_verify`), and the project's *fidelity* oracle — distinct from the OCaml emulator,
which is the *behavioural / system-state* oracle (see AGENT.md §6).

It is **not** part of `dune runtest`. It needs only:

- `verilator` on `PATH` (it is not in the ox/opam toolchain).

The reference Verilog is **not vendored** (its licensing is unclear and we prefer not to
redistribute it). `run.sh` fetches it on demand into `_po/` and checksum-verifies it against
`rtl-sources.txt` (see *Reference RTL* below), so a fresh clone with `verilator` just works.

## Run

```sh
dune build @cosim                       # everything (FP units + SPI + UART R/T + PS/2 kbd + video + mouse), uniform with @boot_checkpoint
bash test/cosim/run.sh                  # everything — the same, run directly
bash test/cosim/run.sh fp_divider       # just one (fp_adder | fp_multiplier | fp_divider | spi | rs232t | rs232r | ps2 | vid | mouse)
bash test/cosim/run.sh spi              # just the SPI master
bash test/cosim/run.sh rs232t           # just the RS232 transmitter
bash test/cosim/run.sh rs232r           # just the RS232 receiver
bash test/cosim/run.sh ps2              # just the PS/2 keyboard
bash test/cosim/run.sh vid              # just the video controller
bash test/cosim/run.sh mouse            # just the PS/2 mouse
```

`dune build @cosim` is the uniform front door (like `@boot_checkpoint`); dune caches it, so re-run
with `--force`, or use `run.sh <unit>` for a single unit. Either way it ensures the reference RTL is
present (fetching it on first run via `fetch-rtl.sh`), builds the OCaml dumper, then
for each unit dumps the Hardcaml port's output over a stimulus set, verilates the reference `.v`,
and asserts the RTL matches the port in **both result and timing** for every stimulus (expect
`0 value-mismatch, 0 cycle-mismatch`):

- **FP units** — the frozen `fp_vectors` stimuli for that unit (`A`/`M`/`D` lines) **+ 20 000
  random fuzz**; asserts `RTL z == port z` **and** `RTL stall-length == port stall-length`.
- **SPI** — corner data words in both rates **+ ~640 random fuzz transfers** with a recorded
  per-cycle MISO stimulus; asserts, **cycle-by-cycle**, `RTL (rdy, sclk, mosi) == port's`, plus
  final `dataRx` and total cycle count (`0 value-, wave-, cycle-mismatch`).
- **RS232T (UART TX)** — corner bytes in both baud rates **+ ~72 random fuzz frames**; asserts,
  **cycle-by-cycle**, `RTL (rdy, TxD) == port's`, plus total frame length (`0 wave-,
  cycle-mismatch`). Output-only, so no value column — `TxD` *is* the value, checked every cycle.
- **RS232R (UART RX)** — the testbench plays the sender, driving a frame on `RxD` (+ a `done`
  ack) in both baud rates **+ ~36 fuzz frames**; a fixed-length trace replay asserts,
  **cycle-by-cycle**, `RTL rdy == port's` plus `RTL data == port's` whenever `rdy` is high
  (`0 value-, wave-mismatch`).
- **PS/2 keyboard** — the testbench plays the keyboard, clocking 11-bit frames on `PS2C`/`PS2D`
  (+ a `done` pop) **+ ~48 frames**; a fixed-length replay asserts, **cycle-by-cycle**, `RTL rdy
  == port's` plus `RTL data == port's` when `rdy` (`0 value-, wave-mismatch`). `shift` is
  `ps2c`-derived (trivially identical); multi-byte FIFO ordering is the co-located test's job.
- **Video controller** — two-clock (`clk` 25 MHz, `pclk` 65 MHz, the 13:5 ratio). A wrapper
  (`vid_cosim.v`) stubs the Xilinx `DCM`/`BUFG` and `force`s `VID`'s internal `pclk` from the
  harness; the harness drives both clocks at the same cadence as the Hardcaml dumper's
  `By_input_clocks`. Replays **~2 scanlines** with per-tick varying `viddata` + an `inv` toggle and
  asserts, **every base tick**, `RTL (req, vidadr, hsync, vsync, RGB) == port's` (`0 mismatch`):
  visible pixels, the 32-word/line DMA, `vidadr`, `hblank` + the `hsync` pulse, the `hcnt` wrap +
  `vcnt` advance. `vblank`/`vsync` (`vcnt>=768`) need a whole frame to reach (the Phase-6 visual
  golden) and are the same comparator-free / SR-latch idiom as their `h` counterparts.
- **PS/2 mouse** — bidirectional open-drain `msclk`/`msdat` (RTL `inout`, `line = drive ? 0 : z`).
  A wrapper (`mouse_cosim.v`) splits each line like the Hardcaml port: `force`s the harness-driven
  resolved value into the DUT and XMR-exports the DUT's pull-low (`req`, `~tx[0]`) as `*_oe`. The
  dumper plays a mouse device through the **bidirectional init handshake to `run`, then 4 movement
  reports** (+ve / −ve signs, buttons, overflow), recording the device's pull-lows; both sides
  resolve `wire = ~(own DUT oe | device low)`, so a divergence shows as an output mismatch. Asserts,
  **every cycle** over ~505 K cycles, `RTL (msclk_oe, msdat_oe, out) == port's` (`0 mismatch`).

Scratch (the downloaded zip, Verilator's `obj_dir`) goes to `$CLAUDE_JOB_DIR/oberon-cosim`; the
only tree write is the fetched `_po/verilog/src/*.v` (git-ignored).

## Reference RTL (fetch-on-demand + checksum pin)

`fetch-rtl.sh` populates `_po/verilog/src/` once, on demand: if the pinned `.v` are
already cached and match, it does nothing; otherwise it downloads `OStationVerilog.zip` from the
upstream URL, verifies the archive SHA-256, extracts `src/*.v`, and verifies each file against
`rtl-sources.txt` before trusting it. The pins are **fidelity-critical**: a mismatch means
upstream drifted from the exact revision the port (and AGENT.md §8's line-number citations) was
verified against, so the co-sim refuses rather than compare against unknown RTL. Updating to a
newer upstream revision is a deliberate edit of `rtl-sources.txt`. Offline fallback: download the
zip yourself and unzip its `src/*.v` into `_po/verilog/src/`.

## How it works

| file | role |
|---|---|
| `dump_fp.ml` | one dumper for all FP units: drive `Risc5.Fp_<unit>` (chosen by the unit-name argument) over the stimuli, dump `"x y [u v] z cycles"` lines (`cycles` = the port's stall length) — the stimulus source |
| `dump_spi.ml` | the SPI dumper (a serial handshake unit, not stall-based): drive `Risc5.Spi` over (`fast`, `data_tx`) with a recorded per-cycle MISO, dump `"fast data_tx data_rx cycles hextrace"` (one hex digit/cycle = `miso·rdy·sclk·mosi`) |
| `dump_rs232t.ml` | the RS232 transmitter dumper (output-only serial handshake): drive `Risc5.Rs232t` over (`fsel`, `data`), dump `"fsel data cycles hextrace"` (one hex digit/cycle = `rdy·txd`) |
| `dump_rs232r.ml` | the RS232 receiver dumper (input-driven): play the sender — drive a frame on `rxd` (+ a `done_` ack), dump `"fsel data hextrace"` (one hex digit/cycle = `done_·rxd·rdy`); fixed-length replay, so no cycles column |
| `dump_ps2.ml` | the PS/2 keyboard dumper (input-driven): play the keyboard — clock a frame on `ps2c`/`ps2d` (+ a `done_` pop), dump `"data hextrace"` (one hex digit/cycle = `done_·ps2c·ps2d·rdy`); fixed-length replay |
| `dump_vid.ml` + `vid_cosim.v` | the video dumper (two-clock, autonomous): run `Risc5.Vid` under `By_input_clocks` (13:5) over ~2 scanlines, dump `"inv viddata req vidadr hsync vsync rgb"` per base tick. `vid.cpp` replays the inputs through `vid_cosim.v` — the real `VID60.v` with `DCM`/`BUFG` stubbed and `pclk` `force`d from the harness — and compares every output each tick. The optional 6th `units_table` column hands `vid_cosim.v` to Verilator |
| `dump_mouse.ml` + `mouse_cosim.v` | the mouse dumper (bidirectional, single-clock): play a PS/2 mouse against `Risc5.Mouse` through the init handshake + 4 reports, dump `"rstn dmc dmd mco mdo out"` per cycle (the device's open-drain pull-lows + the port outputs). `mouse.cpp` replays through `mouse_cosim.v` — the real `MousePM.v` with the `inout` lines split via `force` + XMR — resolving the open-drain against the RTL's own oe, and compares every cycle |
| `cosim.h` | shared harness: universal `cosim_open` + `Unit` + `tick` + `hexval`, and two cross-check runners — `run_drain_cosim` for the stall-based FP units (open → run → drain on `stall` → compare `z`, with `parse_xy`/`parse_xyuv`), and `run_serial_cosim` for the cycle-by-cycle serial units (reset → per-line `replay` → value/wave/cycle tally → summary). Each FP/serial `.cpp` is a thin shell |
| `<unit>.cpp` | Verilator harness, one per unit. FP units are ~8-line shells (name the `Unit`, pick the parser, call `run_drain_cosim`); the serial units (`spi`, `rs232t`, `rs232r`, `ps2`) are a `reset` + a `replay` + `run_serial_cosim`. `vid` (two-clock) and `mouse` (bidirectional `inout`, split via `force`+XMR) keep their own `main` — different shapes |
| `fetch-rtl.sh` | provenance: fetch + checksum-verify the reference `.v` into `_po/` against `rtl-sources.txt` (toolchain-free; idempotent once cached) |
| `run.sh` | glue: a `units_table` (one row per unit) driving build → dump → verilate → cross-check; calls `fetch-rtl.sh` first |

The OCaml dumpers build under `dune build @check` (Verilator-free), so they can't silently rot
even though the cross-check itself only runs via `run.sh`.

## Adding another unit (the CPU core, peripherals)

Every unit is one row in `run.sh`'s `units_table` (`name  .v  top-module  .cpp  dumper`); the
shared `cosim_unit` drives build → dump → verilate → cross-check off that row. Adding a unit is a
new row plus its harness, with one fork on whether it fits the stall-based dumper:

**Stall-based units** (`run`/`stall`/`z`) reuse the shared `dump_fp` dumper — three small steps:

1. a `*_driver ()` in `dump_fp.ml` (build its sim, set its inputs, return `drive`'s
   `(z, cycles)`) plus one arm in the unit-name `match` — the `run` → drain on `stall` → read
   protocol (and its stall-cycle count) is already shared by `drive`;
2. a ~8-line `<unit>.cpp` that names the `Unit` and passes `parse_xy` (or `parse_xyuv`, if it
   carries `u`/`v`) to `run_drain_cosim` — the replay/compare/summary loop is shared;
3. a `units_table` row in `run.sh` with `dump_fp` in the dumper column.

The adder carries `u`/`v` modifiers and a 6-field vector line (`A`); the mul/div units don't
(`M`/`D`, 4-field). The `driver` record's `has_uv`/`tag` fields capture exactly that difference.

**Other interfaces** (handshake/serial peripherals, the SoC) don't fit `run`/`stall`/`z`, so
they get their own dumper + harness — see `dump_spi.ml` / `spi.cpp` as the template: dump a
per-cycle trace (MISO stimulus + the outputs to check), and have the `.cpp` drain the RTL on its
own terminal condition (here `rdy` re-raising) while comparing every cycle. Wire it in with a
`units_table` row naming the new dumper (`cosim_unit`'s one conditional already handles "dumper
takes no `fp_vectors` arg"); a genuinely different dump signature is the only case that needs more
than a row.

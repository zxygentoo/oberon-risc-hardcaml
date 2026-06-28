# test/cosim — RTL-fidelity co-simulation (opt-in)

Confirms a Hardcaml design is **bit-exact to Wirth's original Verilog** — in both result
*and* timing — by driving the reference RTL through **Verilator** and comparing each
stimulus's output against the Hardcaml port. This is the simulation-based preview of the
Phase-8 formal-equivalence proof ([`test/formal`](../formal)), and the project's *fidelity* oracle —
distinct from the OCaml emulator, which is the *behavioural / system-state* oracle (see AGENT.md §6).

It is **not** part of `dune runtest`. It needs only:

- `verilator` on `PATH` (it is not in the ox/opam toolchain).

The reference Verilog is **not vendored** (its licensing is unclear and we prefer not to
redistribute it). The runner fetches it on demand (via `fetch-rtl.sh`) into `test/_po/` and
checksum-verifies it against `rtl-sources.txt` (see *Reference RTL* below), so a fresh clone with
`verilator` just works.

## Run

```sh
dune build @cosim                              # all units (9 + the CPU core), parallel + a PASS/FAIL summary
dune exec test/cosim/cosim_run.exe -- vid      # just one unit, live (fp_adder | fp_multiplier |
                                               #   fp_divider | spi | rs232t | rs232r | ps2 |
                                               #   vid | mouse | core)
dune exec test/cosim/cosim_run.exe -- all 4    # all units, capping parallelism at 4 jobs
```

`dune build @cosim` is the uniform front door (like `@boot_checkpoint`); dune caches it, so re-run
with `--force`. The runner (`cosim_run.ml`) ensures the reference RTL is present (fetching it on
first run via `../fetch-rtl.sh`) and the dumper/capture exes are built **once** up front, then runs
every unit **concurrently** in a forked-worker pool (default one job per core) — Verilator is ~5 s
per stimulus unit, so their wall time is roughly *one* unit, not nine. The **CPU core** is folded in
(see *CPU core* below) and is the heavier one — ~10 s for its first ~2 M-cycle capture, then reuses
the cached ~33 MiB trace — so it's the long pole of a full run's wall time. Each unit's output is captured to
`test/_work/cosim/<unit>/run.log`; the run ends with a PASS/FAIL table (plus the tail of any failing
log) and exits nonzero iff any unit failed. A single `cosim_run.exe -- <unit>` runs **live**
(uncaptured) for debugging.

Each of the nine **stimulus units** dumps the Hardcaml port's output over a stimulus set, verilates
the reference `.v`, and asserts the RTL matches the port in **both result and timing** for every
stimulus (expect `0 value-mismatch, 0 cycle-mismatch`):

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
  `By_input_clocks`. Replays **~2 scanlines** with one stable `viddata` word per 32-px fetch group
  (a faithful memory model — real SRAM holds the fetched word; sampled once per fetch) + an `inv`
  toggle, and asserts, **every base tick**, `RTL (vidadr, hsync, vsync, RGB) == port's`
  (`0 mismatch`): visible pixels, the 32-word/line DMA, `vidadr`, `hblank` + the `hsync` pulse, the
  `hcnt` wrap + `vcnt` advance. **`req` is excluded from the cycle-exact compare** — it's the one
  deliberate CDC departure (our toggle pulse-synchroniser fires the fetch request ~2 clk later than
  `VID60.v`'s async-set `req1`, a metastability-safe substitute), so instead the cosim checks its
  *protocol*: both sides emit the same number of `req` pulses (±1 for the in-flight fetch at the run
  boundary). The exact-timing equivalence is impossible by design; `req`'s correctness is proven by
  `test/formal`'s `vid_invariant` (one req per req0, no loss, all phases) and the per-group-stable
  word is what keeps the *pixel* path cycle-exact despite the `req` sampling shift. `vblank`/`vsync`
  (`vcnt>=768`) need a whole frame to reach (the Phase-6 visual golden) and are the same
  comparator-free / SR-latch idiom as their `h` counterparts.
- **PS/2 mouse** — bidirectional open-drain `msclk`/`msdat` (RTL `inout`, `line = drive ? 0 : z`).
  A wrapper (`mouse_cosim.v`) splits each line like the Hardcaml port: `force`s the harness-driven
  resolved value into the DUT and XMR-exports the DUT's pull-low (`req`, `~tx[0]`) as `*_oe`. The
  dumper plays a mouse device through the **bidirectional init handshake to `run`, then 4 movement
  reports** (+ve / −ve signs, buttons, overflow), recording the device's pull-lows; both sides
  resolve `wire = ~(own DUT oe | device low)`, so a divergence shows as an output mismatch. Asserts,
  **every cycle** over ~505 K cycles, `RTL (msclk_oe, msdat_oe, out) == port's` (`0 mismatch`).

The tenth unit, the **CPU core**, is a boot-stream capture/replay — a different shape; see below.

Scratch (the downloaded zip, Verilator's `obj_dir`s, the core boot trace) goes to `test/_work/cosim`
(git-ignored, in-repo + self-contained); the other write is the fetched `test/_po/verilog/src/*.v`
(also git-ignored). Both `test/_po` and `test/_work` are marked `data_only_dirs` so dune skips them.

## Reference RTL (fetch-on-demand + checksum pin)

`test/fetch-rtl.sh` — hoisted one level up so cosim + formal share it — populates
`test/_po/verilog/src/` once, on demand: if the pinned `.v` are
already cached and match, it does nothing; otherwise it downloads `OStationVerilog.zip` from the
upstream URL, verifies the archive SHA-256, extracts `src/*.v`, and verifies each file against
`rtl-sources.txt` before trusting it. The pins are **fidelity-critical**: a mismatch means
upstream drifted from the exact revision the port (and AGENT.md §8's line-number citations) was
verified against, so the co-sim refuses rather than compare against unknown RTL. Updating to a
newer upstream revision is a deliberate edit of `rtl-sources.txt`. Offline fallback: download the
zip yourself and unzip its `src/*.v` into `test/_po/verilog/src/`.

## How it works

| file | role |
|---|---|
| `<unit>_dump.ml` | the per-unit dumper: drives the Hardcaml port over a stimulus set, dumps a trace to stdout (the stimulus source). Two are shared and take the unit name: `fp_dump` serves the three FP units (`Risc5.Fp_<unit>`, + the `fp_vectors` path), dumping `"x y [u v] z cycles"`; `rs232_dump <rs232t\|rs232r>` covers both UART directions (shared corner/fuzz driver, per-direction frame). The rest are one-per-unit — `spi_dump`/`ps2_dump` dump a per-cycle hex trace, `vid_dump`/`mouse_dump` a two-clock / bidirectional one — and sort next to their `<unit>.cpp` |
| `cosim_dump.ml` | shared OCaml dumper helpers (`rd`, …) the `*_dump.ml` open |
| `cosim.h` | shared C++ harness: universal `cosim_open` + `Unit` + `tick` + `hexval`, and two cross-check runners — `run_drain_cosim` for the stall-based FP units (open → run → drain on `stall` → compare `z`), and `run_serial_cosim` for the cycle-by-cycle serial units (reset → per-line `replay` → value/wave/cycle tally → summary) |
| `<unit>.cpp` | Verilator harness, one per unit. FP units are ~8-line shells; the serial units (`spi`, `rs232t`, `rs232r`, `ps2`) are a `reset` + `replay` + `run_serial_cosim`; `vid` (two-clock) and `mouse` (bidirectional `inout`, split via `force`+XMR) keep their own `main` |
| `vid_cosim.v` / `mouse_cosim.v` | extra `.v` wrappers handed to Verilator beside the reference `.v`: `vid_cosim` stubs the Xilinx `DCM`/`BUFG` and forces `VID`'s `pclk`; `mouse_cosim` splits `MousePM`'s open-drain `inout`s |
| `core_dump.ml` + `core.cpp` | the **CPU core** unit (boot-stream capture/replay — see below). `core_dump` lives in `test/` (it needs `oracle`+`sd_bridge`) and captures the boot trace; `core.cpp` replays it through `RISC5.v` |
| `ram16x1d.v` | the `RAM16X1D` distributed-RAM primitive `Registers.v` infers, supplied for the core replay |
| `../fetch-rtl.sh` + `../rtl-sources.txt` | provenance: fetch + checksum-verify the reference `.v` into `test/_po/` (both at `test/`, shared with formal; toolchain-free; idempotent once cached) |
| `cosim_run.ml` | the **parallel runner**: a typed `units` list (a `Stimulus`/`Core` variant), serialized prep (`../fetch-rtl.sh` + exe builds), then a forked-worker pool — per unit build → dump → verilate → cross-check, captured to `test/_work/cosim/<unit>/run.log` — and a PASS/FAIL summary (nonzero exit iff any failed) |

The OCaml dumpers + `core_dump` build under `dune build @check` (Verilator-free), so they can't
silently rot even though the cross-check itself only runs via `cosim_run`.

## CPU core (boot-stream RTL co-sim)

The core gets a different *shape* of check — not a stimulus dump but a **cycle-level replay of a
real-boot instruction stream**: a *fidelity* spot-check (does our core match `RISC5.v`
cycle-by-cycle?), complementary to `boot_checkpoint`/`visual_golden`, which own boot *correctness*.
By default it replays **~2 M cycles** — reset + ROM init + a solid run of the SD-load driver, a
representative branch/ALU/load-store-stall/byte-mem mix that exercises the core's
decode/control/stall/flags machinery; raise `CAP` to go deeper (handoff ~8 M, inner core 8 M+).
It's folded into the unified runner as the `core` unit:

```sh
dune build @cosim                            # runs it alongside the other units
dune exec test/cosim/cosim_run.exe -- core   # just the core
```

`core_dump.ml` boots the SoC from the real disk (the shared `Sd_bridge` SD card) and records the
core's per-cycle I/O — `rst`/`irq`/`stallX`/`codebus`/`inbus` (inputs) and `adr`/`rd`/`wr`/`ben`/
`outbus` (outputs) — to a 17-byte-per-cycle trace (~2 M cycles, ~33 MiB, cached in
`test/_work/cosim/core`). `core.cpp` Verilates `RISC5.v` + its 8 submodules (`ram16x1d.v` supplies
the `RAM16X1D` primitive `Registers.v` infers, the way `vid_cosim.v` stubs the `DCM`) and replays
the trace: it drives `RISC5.v` with the captured **inputs** and asserts its **outputs** match every
cycle, reporting the **first divergence**.

Why the first output mismatch pins any divergence exactly: both cores start from the same reset
state, and as long as our outputs match the spec's, memory — hence the inputs, which are functions
of memory — evolves identically, so the comparison stays valid right up to the first cycle our core
does something `RISC5.v` wouldn't (a minimal reproducer). This is what found + verified the phase-6b
ALU flag-leak — which sat ~17.3 M cycles in, so reproducing a divergence that deep means raising
`CAP`; `visual_golden`/`boot_checkpoint` surface such bugs at the system level, and this co-sim
then root-causes the exact cycle.

The trace is recorded **pre-edge** (each record = the inputs a state consumes + the outputs it
drives), which keeps it self-consistent across the `rst` 0→1 reset boundary — the codebus consumed
at the first `rst=1` edge (the boot's first instruction is a taken branch, so this is the branch
*target*) would be lost by a post-edge read. The replay drives `rst` per-record and compared-skips
the **2-cycle reset transient** (our port reaches `StartAdr` in the combinational `adr` one cycle
after `RISC5.v`'s `~rst?StartAdr` term; they re-converge at cyc 2). To recapture, delete the cached
trace; `CYC_FROM`/`CYC_TO`/`NOTRACE`/`CAP` env knobs on `core_dump` window a pc/ir/flags/regs dump
for zooming in on a divergence.

## Adding another unit

Every unit is one entry in `cosim_run.ml`'s typed `units` list; the runner drives build → dump →
verilate → cross-check off it. Adding a unit is a new entry plus its harness, with one fork on
whether it fits the stall-based dumper:

**Stall-based units** (`run`/`stall`/`z`) reuse the shared `fp_dump` dumper — three small steps:

1. a `*_driver ()` in `fp_dump.ml` (build its sim, set its inputs, return `drive`'s `(z, cycles)`)
   plus one arm in the unit-name `match` — the `run` → drain on `stall` → read protocol (and its
   stall-cycle count) is already shared by `drive`;
2. a ~8-line `<unit>.cpp` that names the `Unit` and passes `parse_xy` (or `parse_xyuv`, if it
   carries `u`/`v`) to `run_drain_cosim` — the replay/compare/summary loop is shared;
3. a `Stimulus` row in the `units` list with `fp_dump` as the dumper.

The adder carries `u`/`v` modifiers and a 6-field vector line (`A`); the mul/div units don't
(`M`/`D`, 4-field). The `driver` record's `has_uv`/`tag` fields capture exactly that difference.

**Other interfaces** (handshake/serial peripherals) don't fit `run`/`stall`/`z`, so they get their
own `<unit>_dump.ml` + `<unit>.cpp` — see `spi_dump.ml` / `spi.cpp` as the template: dump a
per-cycle trace (stimulus + the outputs to check), and have the `.cpp` drain the RTL on its own
terminal condition (here `rdy` re-raising) while comparing every cycle. Wire it in with a `Stimulus`
row naming the new dumper (the runner's one conditional already handles "dumper takes no
`fp_vectors` arg"). The CPU core's `Core` variant shows the wholly different capture/replay shape.

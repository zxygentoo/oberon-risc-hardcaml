# Nexys 4 board — `nexys4_board`

The Phase-7 board layer: the synthesizable Oberon RISC5 SoC targeted at a Digilent **Nexys 4
(Xilinx Artix-7 XC7A100T)**, plus the Vivado emit → synth → program flow. The library
`nexys4_board` depends on `risc5` **one-way**, so the portable design in `lib/` never depends on
anything board-specific.

The whole design is Hardcaml except one hand-written Verilog shim (`nexys4_top.v`) that
instantiates the vendor primitives (clock, IO buffers, reset). This README is the local map +
how to build; the design rationale is in the root `AGENT.md` (§3 portable-core/board-shim split,
§4 the memory reality, §5 the phase plan, §7 the ISA).

## What's here

| file | what |
|---|---|
| `soc.{ml,mli}` | the board SoC — the top-level Hardcaml design that synthesizes |
| `cellram.{ml,mli}` | PSRAM memory controller + CPU/video arbiter (the memory path) |
| `cache.{ml,mli}` | Phase-10a/b direct-mapped instruction/read cache in front of Cellram |
| `framebuf.{ml,mli}` | Phase-10c framebuffer BRAM shadow — video DMA served on-chip, off the PSRAM port |
| `halftone.{ml,mli}` | the Halftone display mode (AGENT.md §5 row 11) — 8bpp window → 1-bit panel rect, ordered dithering at scanout, claim-muxed against `Framebuf` |
| `Mod/Halftone.Mod` | the display mode's **Oberon driver** (not built here — see below) |
| `Mod/Mandel.Mod` | the driver's demo client — a cooperative Mandelbrot-zoom viewer citizen |
| `cellram_model.{ml,mli}` | behavioural sim double of the external PSRAM chip (**test-only**) |
| `emit_verilog.ml` | emit the board SoC as Verilog (module name `soc_board`), boot ROM from `Risc5.Rom` |
| `nexys4_top.v` | hand-written vendor shim: MMCM / IOBUF / POR — the **only** vendor code |
| `nexys4.xdc` | pin + clock/CDC constraints (from the Digilent master XDC) |
| `gen_verilog.sh`, `*.tcl` | the emit → synth → program / flash flow (below) |

Board integration tests (boot checkpoint, visual golden) live in `test/board/nexys-4/`.

## How the board SoC works

`soc.ml` (the board `Soc`) is `lib/`'s `Soc` with one thing swapped: main memory moves from single-cycle
on-chip BRAM to the external **PSRAM behind `Cellram`**, and the CPU core runs on a
**clock-enable**. Everything else — the MMIO map, peripherals (UART, SPI/SD, PS/2 keyboard +
mouse, GPIO), the video controller — is identical to `lib/soc.ml`.

Why the clock-enable: the RISC5 core assumes single-cycle memory (present an address, get the
word the same cycle). PSRAM can't do that (~70 ns ≈ several clocks). So rather than redesign the
core, we **freeze** it — `Cellram` drives the core's `ce`, pausing the whole machine while an
access is in flight and releasing it the cycle the word is ready. Each *enabled* cycle still sees
the single-cycle memory the core was built for, which is why the Phase 0–8 core is byte-identical
on the board: memory latency is entirely a board-layer concern.

## Cellram — the PSRAM controller

The Nexys 4's main memory is a Micron cellular PSRAM: a **16-bit-wide asynchronous SRAM**
interface, ~70 ns/access, that auto-refreshes itself — so it needs only a simple SRAM-style
controller, no DDR/MIG. `Cellram` adapts it to the 32-bit word interface the CPU and video DMA
expect:

- **Width (16 ↔ 32):** each 32-bit word is two 16-bit halfword phases (low half, high half);
  each phase holds the async pins for `read_cycles` / `write_cycles` clocks (sized for the 70 ns
  chip; the board ships read 6 = 100 ns / write 5 = 83 ns — the read phase deliberately one over
  minimum to buy the FPGA I/O round trip a 30 ns budget, see the synthesis note below).
- **Wait-states → CPU:** `ce = ~mem_pend | <the access completes this cycle>`. The core advances
  only when an access finishes — or freely during a compute (MUL/DIV/FP) stall, when it needs no
  memory (`mem_pend = 0`).
- **Arbitration:** one PSRAM port, two clients. The **video DMA** (framebuffer reads) is
  real-time and wins the bus — it can even *preempt* an in-flight CPU **read** (idempotent; the
  frozen CPU never saw it retire and just restarts). CPU **writes** are never preempted (a
  half-written word would corrupt RAM). This keeps the framebuffer fetch inside its ~477 ns
  raster deadline under load. *(Phase-10c note: the shipped board serves video from the
  `Framebuf` shadow instead and ties `vidreq` low, so the video FSM + preemption logic prune
  away at synthesis; the arbiter remains the proven path for `fb_bram:false` builds.)*
- **On-chip fast path (`cpu_internal`):** boot-ROM fetches and MMIO accesses never touch PSRAM —
  served in a single `ce` cycle, which also keeps each MMIO store one CPU-cycle long so the
  peripheral write strobes fire exactly once.
- **Write buffer (Phase-10d, `?write_buffer` — board emit on):** a 1-entry buffer in front of the
  write path — a PSRAM store retires in **one `ce` cycle** (the slot captures `{adr, ben, wdata}`
  whenever it is free, even mid-video-op) and the write **drains in the background** as an
  `op_wb`-tagged op on the same machinery (excluded from the CPU's `ce` like a video op; never
  preempted, because it is a write). PSRAM reads wait out a pending drain (**drain-before-read**,
  measured +0.4% of clocks), so every read sees fully-drained memory and coherence needs no
  forwarding logic; a second store while the slot is full waits frozen (measured 7.5% of clocks —
  a deeper FIFO's whole remaining ceiling is 1.08×, deferred). One ordering relaxation, documented
  in `cellram.mli`: an MMIO store can become visible before an earlier buffered RAM store lands in
  PSRAM — benign here (no peripheral reads RAM; video reads the `Framebuf` shadow). Landed
  **1.237× same-work** (CPI 1.90→1.53), long-window CPI 1.64→**1.45**, frozen clocks 19.9→9.5%.
  The board ships **`wbuf_depth:2`** — the slot is a small FIFO (slot 0 drains, shift-down on
  completion, order preserved; depth 1 is cycle-identical to the single slot), and depth 2 collects
  the 2-store procedure-prologue bursts that were the depth-1 residual: another **1.066×**
  same-work, CPI 1.45→**1.36**, storeW →1.7% (depth 3+ measured dead at a 1.02× remaining
  ceiling).

Full detail in `cellram.mli`. `cellram_model.ml` is a behavioural double of the chip, wired to
Cellram's pins only in simulation (the board tests); it never synthesizes.

## Cache — the Phase-10a/b cache

The running OS fetches every instruction from PSRAM, so the machine is **memory-bound** (the
Phase-9 benchmark's verdict). `Cache` is a small direct-mapped, write-through instruction/read
cache in front of Cellram that turns most fetches/loads into a **0-stall hit**:

- **0-stall hit:** the tag/data array is **async-read distributed RAM** (LUTRAM — the register
  file's idiom; BRAM can't read combinationally). On a hit, the board `Soc` drops `mem_pend` to
  Cellram, whose `ce = ~mem_pend | …` therefore rises the *same* cycle — the word comes from the
  cache with zero wait and no extra pipeline stage.
- **Coherence, no flush op** (the real machine has no cache, so Oberon has no flush instruction):
  write-through (Cellram's write path is unchanged) + **snoop-invalidate** (a CPU store drops any
  matching cached line). The invariant — *a valid line always equals PSRAM* — makes it
  transparent, so the module loader can write code then jump straight into it. The LUTRAM powers
  up all-invalid, so no reset sequence is needed.
- Default 1024 one-word lines = 4 KB; **optional** (`?icache`, default off — the board emit turns
  it on). ~6× on running-OS code, 93% hit-rate; 60 MHz still closes.
- **Write-update snoop (Phase-10b, `?write_update` — board emit on):** the plain snoop-invalidate
  left the load hit-rate at 58.7% because 96.1% of load misses were its own doing — Oberon's
  store-then-load stack discipline killed the hot lines (measured by the miss autopsy,
  `test/board/nexys-4/bench_boot.ml`). A **word** store that hits now rewrites the line in place with the
  store data — same single write port, and the same write-through transaction lands the identical
  word in PSRAM, so the coherence invariant is untouched; **byte** stores still invalidate. Load
  hit 58.7→98.4%, **1.305× same-work** on running-OS code; WNS +0.708 ns at 60 MHz (the cache-write
  path, one mux deeper, is now the critical path). Proven by the same layers as 10a: the autopsy
  mirror 0-mismatch vs the RTL hit bit, the pc-lockstep A/B, and the byte-identical visual golden
  (`WRITE_UPDATE=1 dune build @visual_golden_board`).

Full detail (incl. the coherence argument) in `cache.mli`.

## Framebuf — the Phase-10c framebuffer shadow

With write-update in, the true residual (measured by the write-update stall profile,
`test/board/nexys-4/bench_boot.ml`) was CPI 1.75 with 25% of clocks frozen — and the video DMA
still occupied the PSRAM port **22.8% of all clocks**, freezing the CPU behind it 5% (measured
same-work ceiling of removing it: 1.180×). `Framebuf` removes that traffic at the source:

- **A write-through shadow; PSRAM keeps the truth.** Every PSRAM-bound store whose word address
  falls in the DMA-addressable span `[Video.org, Video.org + 0x8000)` also writes a BRAM shadow — in
  the same write-through transaction that lands the word in PSRAM, so **shadow ≡ PSRAM window at
  every instant** (both power up zeroed). CPU *loads* are untouched (they read PSRAM/cache as
  before); **video reads the shadow** — a 1-cycle synchronous BRAM read (`vid_ack` the next
  clock, vs the ~11-cycle arbitrated PSRAM read), through `Video`'s existing
  `?viddata_valid`/`?viddata_par` seams. `Video` itself is unchanged.
- **Geometry:** four byte-lane 32768×8 sync-read BRAMs (the `lib/ram.ml` byte-enable idiom; sync
  read is what makes them infer as *block* RAM — **32 RAMB36**, the design's first BRAM use,
  23.7% of the 135 tiles). The span is the full 32768 words `Video.lookahead` can address, so no
  assumption is needed about blanking-time fetches.
- **Result:** same-work **1.180×** — exactly the `?video` gating ceiling, because the shadow read
  never touches the CPU's clock-enable — long-window CPI 1.75 → **1.64**, video port
  occupancy/contention → 0. The residual is now store-wait (18.3% of clocks, 92% of frozen);
  the write-buffer ceiling from here is 1.22× with 4.4× bus-free headroom. 60 MHz closes at
  WNS +0.213 ns (the critical path is still the cache write). **Boots clean on hardware, desktop
  smooth.**
- **Proof:** `Framebuf`'s co-located tests (fill/byte-lane/window edges + read timing); the
  same-work pc-lockstep A/B; and `FB_BRAM=1 WRITE_UPDATE=1 dune build @visual_golden_board` —
  byte-identical desktop *read from the shadow*, plus a direct check that all 32768 shadow words
  equal the PSRAM window (the coherence invariant, asserted rather than inferred).

Full detail in `framebuf.mli`. Optional (`?fb_bram`, default off — the board emit turns it on).

## Mod/ — the display mode's Oberon driver + demo

`Mod/Halftone.Mod` is the Oberon-07 face of the `Halftone` unit: the thin system service
any Oberon program uses to put grayscale pixels on the 1-bit panel (`Claim`, then `Open`
+ `LinearRows` + a threshold upload + `On` gets a working window; `Release` when done.
Single-owner, **enforced at consumer lifetime** — there is one rect in hardware, so
`Claim` takes it for as long as the consumer lives and a second consumer is refused
until `Release`; inside the claim, `Open` reshapes and `Off` blanks through
suspend/resize with the tables untouched). `Mod/Mandel.Mod`
is its demo client — a cooperative Mandelbrot infinite-zoom in an ordinary viewer, zero
DOOM code or content: the display mode's generality witness. They live **here, next to the hardware they drive**, so one commit —
and one submodule pin in a consuming repo — captures design, emulator, driver and demo
together; the driver's address/register constants mirror `halftone.mli`, which carries
the full register-map detail. This repo never compiles them (not dune material): the
sibling `DOOM-on-Oberon`'s `script/mkdsk.sh` reads them from this directory and compiles
them in-image (norebo ORP) into the bootable `DOOM.dsk`, where `DOOM.Run -win` is the
driver's other client — and the on-system tests over there (`run_dsk`) are what exercise
them.

## The 16 KiB icache — DOOM's capacity lever (feat/more-cache)

Phase 10's "capacity-flat" finding was an **Oberon-OS** fact — its hot loops fit a few KB, so
1 KB→256 KB moved the hit-rate 1.6 pt. The **DOOM** workload (the sibling `DOOM-on-Oberon`) is the
opposite. A throwaway access-stream replay (the emulator's *exact* DOOM fetch+load stream through
a cache mirror — bit-identical to this board per the desync oracle) showed **read-miss stall = 51%
of the DOOM frame**, and it is a *capacity* problem, not line-width: **55%** of misses are
instruction fetch (the renderer code footprint), **28%** are loads into the 30.7 KB dither rank
tables, and only **16%** are zone/texture streaming (the one slice a wider line / burst fill would
help). So the board emit now ships a **16 KiB** icache (`lines_log2:12` — 4096-line async-read
LUTRAM, 2822 LUTs, **0 extra BRAM**; up from the 4 KiB / 1024-line default):

- **Measured on hardware** (`-timedemo demo1`, fps on the raw UART): baseline 4 KiB ~4.9 fps →
  **16 KiB 6.8 fps (+39%)**. Oberon is unaffected (still capacity-flat — a bigger cache neither
  helps nor hurts it beyond the LUT/timing cost).
- **32 KiB** (`lines_log2:13`) was tried and gave only **+4%** (7.1 fps — 16 KiB nearly drains the
  miss stream) at a razor-thin WNS +0.005 vs 16 KiB's +0.019, so **16 KiB is the knee**.
- **Timing:** the deeper async-read LUTRAM lengthens the combinational hit path — the 60 MHz
  critical cone — so it routes ~17 ps short and closes **only** via `build.tcl`'s bounded
  post-route `phys_opt` recovery loop (widened to 8 passes). WNS **+0.019 ns**, deterministic.
- **Deferred:** multi-word lines / PSRAM burst fill (DOOM.md §1's predicted lever) — the access
  stream shows they'd help only the 16% streaming slice, and without burst each miss fetches N
  words at full latency (a net loss); capacity is the cheaper, bigger win. Judged against the
  ISA/oracle, not `RISC5.v` timing (a cache is a board block, not in the faithful RTL).

## PS/2 topology — mouse + keyboard (feat/ps2-port-swap)

Two PS/2-protocol devices, two physical ports; **the direction machinery follows the device
role, not the connector**:

- **Mouse = a genuine 3-button PS/2 mouse on a Digilent Pmod PS/2 in JA's top row**
  (`msClk`=D17/JA3, `msDat`=B13/JA1 — the Pmod's pin 3 = CLOCK, pin 1 = DATA). The mouse is
  the *bidirectional* device (the `Mouse` module transmits its enable/sample-rate init by
  pulling the lines low), so these pins carry the two open-drain **IOBUFs** +
  `msclk_oe`/`msdat_oe`. Middle-button interclicks work — the reason for a real 3-button
  mouse. The Pmod feeds the device 3.3 V (JP4 takes an external 5 V if a device won't run
  there; NB a forum report says JP4's VE/GND silkscreen is swapped on some revs).
- **Keyboard = a USB keyboard on the onboard USB-HID port** (`PS2Clk`=F4, `PS2Data`=B2). The
  board's PIC24 bridges USB HID to an emulated PS/2 device; Wirth's `PS2.v` controller never
  transmits, so these are two plain **inputs** (the ref manual explicitly blesses
  receive-only hosts).

Bring-up gotchas, hardware-confirmed:

- **USB keyboard compatibility:** the PIC has **no hub support**, so composite/hub keyboards
  — anything with a USB passthrough port, wireless combo dongles, most gaming boards — never
  enumerate. A plain wired HID keyboard works. Diagnostics: the PIC's aux status LED blinks
  per HID report (enumeration proof); LD12 flashes per PS/2 edge at F4 (our side).
- **Mouse after a JTAG load needs one `btnCpuReset`:** during JTAG configuration the pins
  float (no pull-ups yet), which can disturb the mouse right when the one-shot init fires;
  the reset re-fires init onto stable lines. A QSPI cold boot power-cycles the mouse inside
  the POR window and comes up clean. (Escalation if that ever regresses: the init
  auto-retry.)
- LED map: LD9 = mouse `run`, LD10/11 = X/Y ever decoded, LD12 = keyboard clock activity,
  LD13 = mouse clock activity, LD14 = host pulling the mouse lines (init).

## Build & program

```sh
# 1. emit the SoC to Verilog (boot ROM baked in from Risc5.Rom)
board/nexys-4/gen_verilog.sh                 # → board/_generated/nexys-4/soc_board.v

# 2. synthesize + implement → bitstream (Vivado non-project batch)
vivado -mode batch -source board/nexys-4/build.tcl   # → board/_build/nexys-4/oberon.bit + reports

# 3a. program over JTAG — volatile SRAM config, re-run after a power-cycle
vivado -mode batch -source board/nexys-4/program.tcl

# 3b. …or write the QSPI flash for persistent power-on boot (MODE jumper JP1 = QSPI)
vivado -mode batch -source board/nexys-4/flash.tcl
```

`nexys4_top.v` wraps the emitted `soc_board` with the **MMCM** (100 MHz board oscillator → 60 MHz
system + 65 MHz pixel), the bidirectional PSRAM data-bus **IOBUFs**, the mouse open-drain IOBUFs
(on the Pmod PS/2 pins — see the PS/2 topology above), and a power-on **reset**. The tuning knobs — 60 MHz clocking, `read_cycles`, the SPI divider, and
`icache`/`lines_log2:12`/`write_update`/`fb_bram`/`write_buffer`/`wbuf_depth:2` and `read_cycles:6` — live in `emit_verilog.ml`. Part `xc7a100tcsg324-1`, top `nexys4_top`;
(One synthesis note, Phase-10d: the rc=5 PSRAM I/O budget (13.3 ns split across the address-out and
data-in groups) became a standing knife-edge as the design grew — `RamUBn` failed by 0.163 ns, then
two builds grazed at +0.130 and +0.009. `build.tcl` runs Explore-class implementation directives,
and the structural fix is in: `read_cycles:6` re-derives the budget to 30 ns (12/12 split, ~5 ns
measured headroom per group), for a measured 0.86% same-work cost — the worst path is back on the
internal cache-write path, where it has lived since 10b.)
outputs land in the git-ignored `board/_build/nexys-4/`.

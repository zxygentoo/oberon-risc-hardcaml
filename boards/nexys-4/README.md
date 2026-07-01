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
| `soc_board.{ml,mli}` | the board SoC — the top-level Hardcaml design that synthesizes |
| `cellram.{ml,mli}` | PSRAM memory controller + CPU/video arbiter (the memory path) |
| `icache.{ml,mli}` | Phase-10a direct-mapped instruction/read cache in front of Cellram |
| `cellram_model.{ml,mli}` | behavioural sim double of the external PSRAM chip (**test-only**) |
| `emit_board_verilog.ml` | emit `soc_board` as Verilog, boot ROM baked in from `Risc5.Rom` |
| `nexys4_top.v` | hand-written vendor shim: MMCM / IOBUF / POR — the **only** vendor code |
| `nexys4.xdc` | pin + clock/CDC constraints (from the Digilent master XDC) |
| `gen_verilog.sh`, `*.tcl` | the emit → synth → program / flash flow (below) |

Board integration tests (boot checkpoint, visual golden) live in `test/boards/nexys-4/`.

## How the board SoC works

`soc_board` is `lib/`'s `Soc` with one thing swapped: main memory moves from single-cycle
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
  each phase holds the async pins for `read_cycles` / `write_cycles` clocks (sized for 70 ns).
- **Wait-states → CPU:** `ce = ~mem_pend | <the access completes this cycle>`. The core advances
  only when an access finishes — or freely during a compute (MUL/DIV/FP) stall, when it needs no
  memory (`mem_pend = 0`).
- **Arbitration:** one PSRAM port, two clients. The **video DMA** (framebuffer reads) is
  real-time and wins the bus — it can even *preempt* an in-flight CPU **read** (idempotent; the
  frozen CPU never saw it retire and just restarts). CPU **writes** are never preempted (a
  half-written word would corrupt RAM). This keeps the framebuffer fetch inside its ~477 ns
  raster deadline under load.
- **On-chip fast path (`cpu_internal`):** boot-ROM fetches and MMIO accesses never touch PSRAM —
  served in a single `ce` cycle, which also keeps each MMIO store one CPU-cycle long so the
  peripheral write strobes fire exactly once.

Full detail in `cellram.mli`. `cellram_model.ml` is a behavioural double of the chip, wired to
Cellram's pins only in simulation (the board tests); it never synthesizes.

## Icache — the Phase-10a cache

The running OS fetches every instruction from PSRAM, so the machine is **memory-bound** (the
Phase-9 benchmark's verdict). `Icache` is a small direct-mapped, write-through instruction/read
cache in front of Cellram that turns most fetches/loads into a **0-stall hit**:

- **0-stall hit:** the tag/data array is **async-read distributed RAM** (LUTRAM — the register
  file's idiom; BRAM can't read combinationally). On a hit, `soc_board` drops `mem_pend` to
  Cellram, whose `ce = ~mem_pend | …` therefore rises the *same* cycle — the word comes from the
  cache with zero wait and no extra pipeline stage.
- **Coherence, no flush op** (the real machine has no cache, so Oberon has no flush instruction):
  write-through (Cellram's write path is unchanged) + **snoop-invalidate** (a CPU store drops any
  matching cached line). The invariant — *a valid line always equals PSRAM* — makes it
  transparent, so the module loader can write code then jump straight into it. The LUTRAM powers
  up all-invalid, so no reset sequence is needed.
- Default 1024 one-word lines = 4 KB; **optional** (`?icache`, default off — the board emit turns
  it on). ~6× on running-OS code, 93% hit-rate; 60 MHz still closes.

Full detail (incl. the coherence argument) in `icache.mli`.

## Build & program

```sh
# 1. emit the SoC to Verilog (boot ROM baked in from Risc5.Rom)
boards/nexys-4/gen_verilog.sh                 # → boards/_generated/nexys-4/soc_board.v

# 2. synthesize + implement → bitstream (Vivado non-project batch)
vivado -mode batch -source boards/nexys-4/build.tcl   # → boards/_build/nexys-4/oberon.bit + reports

# 3a. program over JTAG — volatile SRAM config, re-run after a power-cycle
vivado -mode batch -source boards/nexys-4/program.tcl

# 3b. …or write the QSPI flash for persistent power-on boot (MODE jumper JP1 = QSPI)
vivado -mode batch -source boards/nexys-4/flash.tcl
```

`nexys4_top.v` wraps the emitted `soc_board` with the **MMCM** (100 MHz board oscillator → 60 MHz
system + 65 MHz pixel), the bidirectional PSRAM data-bus **IOBUFs**, the mouse open-drain IOBUFs,
and a power-on **reset**. The tuning knobs — 60 MHz clocking, `read_cycles`, the SPI divider, and
`icache:true` — live in `emit_board_verilog.ml`. Part `xc7a100tcsg324-1`, top `nexys4_top`;
outputs land in the git-ignored `boards/_build/nexys-4/`.

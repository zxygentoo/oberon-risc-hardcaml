# The Nexys 4 board layer — `nexys4_board`

The Oberon RISC5 SoC as it runs on a Digilent **Nexys 4** (Xilinx Artix-7 XC7A100T, the
original board with cellular RAM), and the Vivado flow that builds it. The library
`nexys4_board` depends on `risc5`, never the reverse: the portable design in `lib/` knows
nothing of the board.

Everything here is Hardcaml except one hand-written Verilog file, `nexys4_top.v`, which
holds the vendor primitives: the clock generator, the I/O buffers, the reset.

## What is here

| File | What |
|---|---|
| `soc.{ml,mli}` | the board SoC: the top-level design that is synthesized |
| `build_config.{ml,mli}` | the machine's knobs as one value; `shipped` is what the bitstream contains, with the reason for each setting |
| `cellram.{ml,mli}` | the PSRAM controller, the CPU/video arbiter and the write buffer |
| `cache.{ml,mli}` | the direct-mapped read cache in front of Cellram |
| `framebuf.{ml,mli}` | a block-RAM copy of the framebuffer, which video reads instead of the PSRAM |
| `halftone.{ml,mli}` | the 8-bit display mode: a window of 8-bit pixels dithered onto the 1-bit screen |
| `Mod/Halftone.Mod`, `Mod/Mandel.Mod` | Halftone's Oberon driver, and a demo client (not built here; see below) |
| `cellram_model.{ml,mli}` | a behavioural model of the PSRAM chip, for tests only |
| `emit_verilog.ml` | emits the board SoC as Verilog (module `soc_board`), the boot ROM included |
| `nexys4_top.v` | the vendor shim: MMCM, IOBUFs, power-on reset |
| `nexys4.xdc` | pins, clocks, the clock-domain crossing and the PSRAM I/O budget |
| `gen_verilog.sh`, `*.tcl` | the flow: emit, build, program, flash |

The board's gates (the boot checkpoint, the visual golden) and its gauge are in
`test/board/nexys-4/`.

## How the board SoC works

The board SoC is `lib/`'s SoC with main memory moved from single-cycle RAM to the
external **PSRAM**. The MMIO map, the peripherals and the video controller are the same.

The RISC5 core assumes memory that answers in the cycle it is asked. The PSRAM takes
about 70 ns, several clocks. So the core is not redesigned: it is **frozen**. `Cellram`
drives the core's clock enable, pausing the whole machine while an access is in flight
and releasing it on the cycle the word arrives. Every enabled cycle still sees the
single-cycle memory the core was built for, which is why the core in `lib/` runs here
unchanged. Memory latency is the board layer's concern alone.

Three more blocks then take most of that latency away again: a cache for reads, a
buffer for writes, and a copy of the framebuffer for video.

## The shipped configuration

`Build_config.shipped` is the one statement of what the bitstream contains. The emitter
builds from it and the board gates boot it. The reasons are next to each value in
`build_config.ml`; in short:

| Setting | Value | Why |
|---|---|---|
| system clock | 64 MHz (the pixel clock is 65) | what the PSRAM read budget allows; see "Clocks and timing" |
| PSRAM read phase | 6 clocks, 93.75 ns | the chip's 70 ns plus the FPGA's I/O round trip |
| PSRAM write phase | 5 clocks, 78.1 ns | a deliberate deviation from the datasheet; see below |
| multipliers | DSP slices, two pipeline stages | takes the multiply off the critical path |
| cache | 4096 lines (16 KiB), stores update it | 4 KiB is enough for Oberon; DOOM needs 16 |
| framebuffer shadow | on | takes video off the PSRAM port |
| Halftone | on | idle until a client turns it on |
| write buffer | two entries | a store retires in one cycle |
| UART | 115200 baud at both rate settings | |
| slow SPI clock | clk/256, 250 kHz | SD-card initialisation allows 400 kHz at most |

What each layer buys, measured on the running OS (`dune build @bench_boot`; the method is
in `test/bench/README.md`):

| | Clocks per instruction | Clocks frozen on memory | Over the same work |
|---|---|---|---|
| PSRAM alone | 27.80 | 94.8% | |
| + cache | 1.77 | 27.5% | 5.14× |
| + stores update the cache | 1.50 | 14.5% | 1.66× |
| + framebuffer shadow | 1.44 | 11.1% | 1.19× |
| + write buffer | 1.34 | 4.5% | 1.07× |
| + its second entry | 1.30 | 1.6% | 1.03× |

## Cellram — the PSRAM controller

The Nexys 4's main memory is a Micron cellular PSRAM (16 MiB): a 16-bit asynchronous
SRAM interface, about 70 ns per access, that refreshes itself. It needs only a simple
SRAM-style controller. Main memory has to live there: the FPGA's block RAM is about
607 KB, less than Oberon's 1 MB map, so block RAM is spent where it pays (the
framebuffer shadow, Halftone's RAMs). The chip also has a synchronous burst mode
(104 MHz), which is not used.

`Cellram` adapts the chip to the 32-bit word interface the core and the video DMA expect:

- **16 bits to 32.** A word is two halfword phases, low half then high. Each phase holds
  the pins for `read_cycles` or `write_cycles` clocks.
- **Wait states.** The core advances when its access completes — or freely while it
  needs no memory, as during a multiply, divide or floating-point stall.
- **Arbitration.** One PSRAM port serves two clients. The video DMA is real-time and
  wins: it can even preempt a CPU read in flight (a read can be repeated; the frozen
  core never saw it finish). A CPU write is never preempted, since half a word written
  would corrupt memory. The shipped board serves video from the framebuffer shadow and
  ties this port's video request off, so the video path is pruned at synthesis; the
  arbiter remains for builds without the shadow, and the bare-controller checkpoint
  boots through it.
- **A fast path on the FPGA.** Boot-ROM fetches and MMIO accesses never touch the PSRAM.
  They complete in one enabled cycle, which also keeps each MMIO store one core cycle
  long, so a peripheral's write strobe fires exactly once.
- **The write buffer.** A store to the PSRAM retires in one cycle into a small FIFO and
  is written in the background. A read waits for the buffer to drain first, so every
  read sees memory fully written and nothing has to be forwarded. A store that finds the
  FIFO full waits. One ordering is relaxed: an MMIO store can take effect before an
  earlier buffered RAM store has reached the PSRAM. That is harmless here — no
  peripheral reads RAM, and video reads the shadow. Two entries collect the two-store
  bursts of a procedure's entry code; a third measured no gain.

The contract is in `cellram.mli`. `cellram_model.ml` models the chip for the tests; the
board gates hold it to the datasheet's timing.

## Cache

`Cache` is a direct-mapped, write-through read cache in front of Cellram, for
instruction fetches and data loads alike.

- **A hit costs no cycle.** The tag and data array is distributed RAM, read
  asynchronously (block RAM cannot be read in the same cycle). On a hit the access never
  becomes pending and the core is not frozen: no wait, no extra pipeline stage.
- **It stays coherent without a flush.** The original machine has no cache, so Oberon
  has no flush instruction, and the module loader writes code and jumps straight into
  it. Every store goes through to the PSRAM, and a store that hits a cached line
  rewrites the line (a word store) or drops it (a byte store). So a valid line always
  equals the PSRAM. The RAM powers up all invalid and needs no reset sequence.
- **Stores update, not just invalidate.** Oberon stores to a stack slot and loads it
  straight back. When stores only dropped lines, the load hit rate was 66%; with update
  it is 99.6% (fetches hit 99.97%).
- **16 KiB is DOOM's size.** The OS's hot code fits in 4 KiB, and a larger cache does
  nothing for it. DOOM's renderer and its 30.7 KB of dither tables do not fit, and
  16 KiB gained it 39% in frame rate on hardware. 32 KiB added 4% more, with twice the
  LUT RAM and almost no timing slack.

The coherence argument is in `cache.mli`.

## Framebuf — the framebuffer shadow

Video reads a word of the framebuffer every 32 pixels. Through the PSRAM that occupied
the port for about 23% of all clocks and froze the core behind it. `Framebuf` takes that
traffic away:

- **A write-through copy; the PSRAM keeps the truth.** Every store into the framebuffer's
  address span also writes a block-RAM shadow, in the same transaction that writes the
  PSRAM. CPU loads are untouched: they read the PSRAM, or the cache, as before. Video
  reads the shadow, a one-cycle synchronous read in place of a dozen clocks through the
  arbiter. `Risc5.Video` itself is unchanged.
- **Geometry.** Four byte-lane RAMs of 32,768 bytes, 32 RAMB36 in all. The span is every
  word the video controller can address, so nothing is assumed about fetches during
  blanking.
- **Checked.** The board's visual golden reads the desktop from the shadow, and also
  requires all 32,768 shadow words to equal the PSRAM's copy.

Detail in `framebuf.mli`.

## Halftone — an 8-bit display mode

Oberon's screen is one bit per pixel. `Halftone` shows a window of 8-bit pixels in a
rectangle of that screen, dithered as the picture is scanned out: each pixel goes through
a tone table and is compared with a threshold map, both uploaded by the client. The
hardware holds only the mechanism. Tone, thresholds, scaling and the layout of rows are
the client's, written through two windows of high memory (pixels at `0x310000`, tables at
`0x30E000`), and geometry changes take effect between frames.

It is a second shadow next to `Framebuf`: inside the rectangle, and only while the mode
is on, it answers the video controller's fetch; everywhere else the mono shadow does.
DOOM draws through it. The register map and the timing are in `halftone.mli`.

## Mod/ — Halftone's Oberon driver and a demo

`Mod/Halftone.Mod` is the Oberon-07 side of Halftone: the small system service a program
uses to put grey pixels on the screen (`Claim`, then `Open`, the tables, `On`; `Release`
when done). There is one rectangle in hardware, so ownership is exclusive for as long as
the client lives. `Mod/Mandel.Mod` is a demo client, a Mandelbrot zoom in an ordinary
Oberon viewer.

They live here, next to the hardware they drive, so one commit holds the design, the
driver and the demo together; the driver's addresses mirror `halftone.mli`. This
repository does not compile them. `DOOM-on-Oberon`'s `script/mkdsk.sh` reads them from
this directory and compiles them into its disk image, and its tests exercise them.

## Clocks and timing

`nexys4_top.v` makes two clocks from the board's 100 MHz oscillator with one MMCM:
64 MHz for the system and 65 MHz for pixels (1024 × 768 at 60 Hz). The two domains meet
only in the video controller's fetch request, through a synchroniser.

- **Why 64 MHz.** At 64 MHz the six-clock read phase is 93.75 ns. The chip takes 70 of
  them; the other 23.75 are the FPGA's round trip, out through the address pads and back
  in through the data pads, which `nexys4.xdc` constrains to 11.7 ns each way. At 65 MHz
  the round trip would have 22.3 ns, less than the paths need, so a faster clock means a
  seventh read clock.
- **The write phase deviates from the datasheet.** With five write clocks, the address,
  chip enable and byte enables are valid 62.5 ns before the end of a write, where the
  datasheet asks for 70. The write pulse itself (45 ns) is met. Six clocks would meet
  everything and cost 6% of DOOM's frame rate; five passed an 11 MiB write and read-back
  test on the board. A board that shows memory corruption should try `write_cycles` 6
  first.
- **Timing closes with little to spare.** The shipped build meets timing by 0.004 ns.
  `build.tcl` uses the timing-driven placement directive and, if routing lands a few
  picoseconds short, repeats post-route optimisation up to eight times; it refuses to
  write a bitstream that misses timing. The critical path is the cache's hit path.
- **One source of truth.** A clock-dependent number lives in three places: the knobs in
  `build_config.ml`, the MMCM in `nexys4_top.v`, the budget in `nexys4.xdc`. A test in
  `build_config.ml` reads the other two and checks that they agree.

## PS/2: mouse and keyboard

Two devices that speak PS/2, on two ports. The direction logic follows the device's
role, not the connector:

- **The mouse is a real 3-button PS/2 mouse on a Digilent Pmod PS/2 in the top row of
  JA** (`msClk` = D17/JA3, `msDat` = B13/JA1). The mouse is the bidirectional device:
  the `Mouse` module sends its initialisation by pulling the lines low, so these pins
  have the two open-drain IOBUFs. The middle button works, which is the reason for a
  real 3-button mouse. The Pmod feeds the device 3.3 V; JP4 takes an external 5 V for a
  mouse that will not run on that (one report says JP4's silkscreen is swapped on some
  revisions).
- **The keyboard is a USB keyboard on the board's USB-HID port** (`PS2Clk` = F4,
  `PS2Data` = B2). The board's PIC bridges USB to an emulated PS/2 device. Wirth's
  keyboard controller never transmits, so these are two plain inputs.

Pitfalls, each met on the board:

- **Not every USB keyboard works.** The PIC has no hub support, so anything that
  presents a hub — a keyboard with a USB pass-through port, a wireless combo dongle,
  most gaming keyboards — never enumerates. A plain wired keyboard works. To tell where
  a dead keyboard stops: the PIC's own status LED blinks on each USB report, and LD12
  flashes on each PS/2 clock edge that reaches the FPGA.
- **After a JTAG load the mouse needs one press of the reset button.** While the FPGA is
  being configured its pins float, which can disturb the mouse just as the one-shot
  initialisation fires; the reset fires it again on steady lines. A power-on boot from
  flash comes up clean.
- **The LEDs.** LD8 blinks with the system clock and LD15 shows the MMCM locked. LD9 is
  lit once the mouse is initialised; LD10 and LD11 once X and Y movement has been
  decoded; LD12 shows keyboard clock activity, LD13 mouse clock activity, LD14 the host
  pulling the mouse's lines.

## Build and program

```sh
# 1. emit the SoC as Verilog, the boot ROM included
board/nexys-4/gen_verilog.sh                          # → board/_generated/nexys-4/soc_board.v

# 2. synthesize, place and route (Vivado, non-project batch)
vivado -mode batch -source board/nexys-4/build.tcl    # → board/_build/nexys-4/oberon.bit and reports

# 3a. load over JTAG: gone at the next power cycle
vivado -mode batch -source board/nexys-4/program.tcl

# 3b. or write the QSPI flash, for boot at power-on (jumper JP1 on QSPI)
vivado -mode batch -source board/nexys-4/flash.tcl
```

The part is `xc7a100tcsg324-1` and the top module `nexys4_top`; we build with Vivado
2025.2. `build.tcl` refuses to run on a `soc_board.v` older than the design's sources,
and removes the old bitstream first, so a stale file is never programmed by mistake. The
outputs are git-ignored.

To change the machine, edit `Build_config.shipped`, emit again, and run the board gates
before the build: `dune build @boot_checkpoint_board @visual_golden_board`.

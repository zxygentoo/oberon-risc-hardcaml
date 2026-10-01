# The measurement gauges

Measure before you optimise, and again after. These print **reports, not verdicts**, so
they stay out of `dune runtest` and run by alias; `dune build @check` builds them so they
cannot rot. Two of them do fail on an inconsistency (noted below).

| Alias | Measures | Scope |
|---|---|---|
| `dune build @bench` | cycles per operation under each choice of multipliers | one instruction through the core, no memory |
| `dune build @profile_boot` | how often MUL and DIV execute over a boot | the oracle (instruction level) |
| `dune build @bench_boot` | the board machine: where its clocks go, what each layer of the memory stack buys, why reads miss | the whole board SoC behind the PSRAM model (`test/board/nexys-4/`) |

`bench_core` and `profile_boot` are target-independent and live here. `bench_boot` is
board-specific through and through and lives with the board tests.

## `bench_core` — one operation (`@bench`)

Pokes an instruction and its operands into the core, runs to retirement and counts
cycles, for each `Cpu.multipliers` choice. The three cores must compute the same result;
a difference fails the run.

```
                             iterative  DSP, combinational       DSP, 2 stages
ADD                                  2                   2                   2
MUL                                 34                   2                   3
MUL' (unsigned)                     34                   2                   3
DIV                                 34                  34                  34
FML                                 26                   2                   3
```

The board ships the 2-stage DSP products: one cycle more per multiply than the
combinational ones, in exchange for taking the multiply off the critical path.

## `profile_boot` — how often it happens (`@profile_boot`)

Steps the oracle through reset, the handoff and into the running system, decoding each
executed instruction:

```
MUL/DIV density: 0.104% of all instr  →  Amdahl stall ceiling 3.32%
```

A multiply that is 11 to 17 times faster, on one instruction in a thousand: the DSP
multipliers buy clock frequency, not throughput.

## `bench_boot` — the board machine (`@bench_boot`)

Boots the board SoC from the real disk to the OS handoff, then runs the OS for a window
of 2 M instructions (or 20 M clocks) and watches every system clock. The machine is what
the bitstream ships (`Build_config.shipped`), or that with the board gates' environment
knobs applied — so a candidate change is measured by setting its knob:

```
dune build @bench_boot                                              # everything
dune exec test/board/nexys-4/bench_boot.exe -- profile              # one gauge
LINES_LOG2=10 dune exec test/board/nexys-4/bench_boot.exe -- profile
```

The machines of a run simulate in parallel, one forked worker each (seven for the full
report: about 4 minutes on a host with the cores for it, where the gauges it replaced
took 20).

**profile** — every clock of the window in one of six buckets: the core advanced and
retired an instruction, spent a load/store data cycle, or ground through an iterative
unit; or it sat frozen on the PSRAM for a fetch, a load or a store. The shipped machine:

```
reset to the handoff: 26097357 clocks.  The window past it: 2000000 instructions in 2601599 clocks = 1.30 clocks per instruction.
frozen on the PSRAM: 41038 clocks = 1.6% (reads 0.5%, stores 1.1%)
cache: fetches 99.97% hit, loads 99.64% hit;  30795 PSRAM stores (1 per 64 instructions)
```

**ladder** — the same machine with its memory stack removed, then put back a layer at a
time. Each rung is profiled, and compared with the rung above it over the same work:

```
rung                         boot   instrs    CPI  frozen  storeW  fetch hit  load hit   the same work as the rung above
PSRAM only               28349987   719412  27.80   94.8%    3.4%          -         -
+ cache                  27710417  2000000   1.77   27.5%   11.6%     99.97%    66.26%   5.139x  (861553 -> 167664 clocks over 28985 instructions)
+ write-update           26769987  2000000   1.50   14.5%   13.9%     99.97%    99.64%   1.662x  (172210 -> 103633 clocks over 31939 instructions)
+ framebuffer shadow     26598703  2000000   1.44   11.1%   10.7%     99.97%    99.64%   1.186x  (100864 -> 85044 clocks over 30369 instructions)
+ write buffer           26244269  2000000   1.34    4.5%    4.1%     99.97%    99.64%   1.074x  (2879719 -> 2681879 clocks over 2000000 instructions)
+ depth 2                26097357  2000000   1.30    1.6%    1.1%     99.97%    99.64%   1.031x  (2681879 -> 2601599 clocks over 2000000 instructions)

the whole stack against the PSRAM alone: 17.73x over the same 28985 instructions (29.72 -> 1.68 clocks per instruction)
```

**autopsy** — why reads miss. An independent model of the cache (a valid bit and a tag
per line, the policy with none of the data) follows the design from reset and classifies
each miss of the window: the line held another address, a store dropped it, or it was
never filled. The model must predict the design's own hit bit on every read; a
disagreement fails the run. On the shipped machine: 0 disagreements, and 928 of the 934
misses in the window are first touches.

### Reading the numbers

- **"The same work."** Two machines that boot the same disk reach the handoff in the same
  architectural state (the boot checkpoint proves it) and then execute the same
  instruction stream, until the first timing-dependent poll — the SD card, the ms timer —
  sends the faster one down a different path. Over that aligned prefix their clock counts
  compare like for like. A fixed-length window does not: the faster machine gets further
  into the boot and averages different code.
- **The window is the OS coming up, and that is SD-card work.** Oberon's SD driver sends
  idle bytes at the slow SPI clock around every command, and the core polls through each
  one. At the shipped divider (clk÷256, 2048 clocks a byte) those poll loops are most of
  the window: cheap instructions that hit the cache and store nothing. So the figures
  describe this machine booting to its desktop, not a compute-bound program — and they
  move with the SPI divider. `SPI_DIV_LOG2=2` (the boot gates' fast mode) shrinks the
  polling and leaves a denser window: 1.38 clocks per instruction, 2.9% frozen, a store
  every 21 instructions instead of every 64, and the last two rungs at 1.197x and 1.102x.
  Compare runs at one divider only.
- **Two controls on the shipped figure.** With the 4 KiB cache (`LINES_LOG2=10`) the
  window costs 1.32 clocks per instruction and 3.1% frozen; with the iterative
  multipliers (`FAST_MUL=0`) it costs 1.30, 0.2% more clocks.
- **The model is behavioural.** The PSRAM is `Cellram_model`, held to the datasheet's
  access times at the configuration's clock. The numbers are for ratios and for finding
  the lever, not for wall-clock.

## History

The gauges were built during the compute and memory arcs (`build-log.md`, Phases 9 and
10), and the figures recorded there — the 5.94x cache, 1.305x write-update, 1.180x
framebuffer shadow, 1.237x write buffer, 1.066x depth 2, running-OS CPI 26.28 → 1.37 —
were measured on the machine of the time: a 4 KiB cache, the iterative multipliers, the
25 MHz timer and SPI constants, 5-cycle PSRAM phases (6 for the last figure). The present
bench was checked against them on that configuration and reproduces each to the clock;
on the shipped configuration it gives the table above.

Gauges that answered their question and were retired with that rework (they are in the
history before it): the end-to-end boot with and without the DSP multipliers (0.00%),
the `read_cycles` 2 → 5 boot sweep (~24% of boot clocks were PSRAM wait), the
video-gating counterfactual and its `?video` seam (the framebuffer shadow then measured
exactly that ceiling), the counterfactual snoop policies replayed by the autopsy (they
became write-update; write-allocate was not worth it), the write-buffer ceiling
projection, the `read_cycles` 5-against-6 pair (0.86%), and the cache-size sweep (set
`LINES_LOG2` instead).

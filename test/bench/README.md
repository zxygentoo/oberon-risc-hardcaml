# Phase-9 benchmarks (the gauge index)

Measure-before/after-you-optimise gauges for the Phase-9 optimisation pass (AGENT.md §5).
They print **reports, not pass/fail assertions**, so they're kept out of the always-on
`dune runtest` and driven by alias. Together they answer one question in three views:
**what did the DSP multipliers and the 50 → 60 MHz clock actually buy, end to end?**

This README indexes all three; the two *target-independent* gauges (`bench_core`,
`profile_boot`) live here, while `bench_boot` — board-specific through and through — lives
in the board-test mirror, `test/boards/nexys-4/`. The aliases work from anywhere.

The short answer, measured: a big *local* win (MUL 17× faster) that Amdahl shrinks to ~nil
*aggregate*, because the machine is memory-bound. The broad, real win is the clock (1.2×);
the next real lever is memory, not compute.

## The three gauges

| Alias | Measures | Scope |
|---|---|---|
| `dune build @bench` | MUL/DIV **cycles per op**, iterative vs DSP | one op, memoryless |
| `dune build @profile_boot` | MUL/DIV **dynamic density** over a boot | oracle (instruction-level, no memory model) |
| `dune build @bench_boot` | **total boot cycles** on the PSRAM SoC | whole machine, wait-states and all (`test/boards/nexys-4/`) |

### `bench_core` — per-op cost (`@bench`)
White-box A/B in one binary: poke IR + operands, run to retirement, count cycles, swapping
the multiplier via the core's `Units` seam. Result:

```
MUL signed   34 → 2 cycles   (17.0x faster per MUL).  DIV unchanged (still iterative).
```

The FP multiply is analogous (25 → 2) via the same seam. This is the number that *looks*
impressive — and is, per multiply.

### `profile_boot` — how often does it even happen (`@profile_boot`)
Steps the OCaml oracle (same instruction stream as the hardware) through reset → OS handoff
→ into the running system, decoding each executed instruction. Result:

```
MUL/DIV density: 0.104% of all instr  →  Amdahl stall ceiling 3.32%
projected compute speedup if MUL drops 33→2:  ~1.03x
```

So the 17× per-op win rides on ops that are ~1-in-1000. Amdahl caps the *compute* payoff at
~3%.

### `bench_boot` — the whole machine (`@bench_boot`, in `test/boards/nexys-4/`)
Boots the real memory path — the board `Soc` (core on a clock-enable, main memory behind
`Cellram` inserting `read_cycles`/`write_cycles` wait-states, driven from the real disk via
the SD bridge) — to the OS handoff, counting total cycles. Two probes:

```
DSP mul, end-to-end (read_cycles=5):  faithful 9,591,225  vs  fast_mul 9,591,225  →  +0.00%
PSRAM wait (read_cycles sweep 2→5):   ~24% of boot cycles are PSRAM latency
```

- **DSP mul: 0.00% end-to-end on boot.** Amdahl made concrete — boot is ~0.1% MUL.
- **PSRAM wait ≈ 24%** of boot cycles, isolated cleanly by the `read_cycles` sweep: `rc`
  only touches PSRAM accesses, so the `rc 2→5` delta (+3 cycles/half-word) is *pure* wait,
  denominator-free. (We deliberately quote **no CPI**: the SoC re-polls the slow SPI far
  more than the oracle, so the oracle's instruction count is the wrong denominator.)

**Caveat that matters:** boot runs code from the on-chip **ROM fast-path** (no PSRAM wait on
fetch) and is dominated by the SD image-copy. The *running OS* fetches **every instruction
from PSRAM**, so it is **more** memory-bound than boot's 24% shows. Boot is a lower bound on
memory pressure, not an upper one.

## The end-to-end read-off

Composing the three:

- **Per op:** MUL 17× faster (`bench_core`).
- **Per program:** MUL is 0.1% of instructions → ≤3.3% compute ceiling → ~1.03× projected
  (`profile_boot`) → **0.00% measured** on boot (`bench_boot`).
- **Where the cycles actually go:** ≥24% in PSRAM wait on boot, more on the running OS
  (`bench_boot`).
- **The win already banked:** the **50 → 60 MHz clock — 1.2× wall-clock**, applied to
  compute *and* memory alike. That, not the DSP mul, is the broad end-to-end speedup.

**Direction this points:** the next real lever is **memory latency — an I-cache (every OS
fetch is currently a multi-cycle PSRAM read) or a wider/burst PSRAM path — not more
compute.** The DSP multipliers were correct to build (they're free once the DSP48s are
there, and they took the multiply *off the critical path*, which is what let the clock reach
60 MHz) — but as an end-to-end *throughput* play they're Amdahl-bound. See AGENT.md §5 for
the Phase-9 log and the deferred Newton-Raphson divider.

## The Phase-10 gauges (all in `bench_boot`, same alias)

Phase 10 turned `bench_boot` into the memory-arc measurement bench. Everything below runs
the running OS (cache on, boot to the handoff, then a 2M-instruction window) unless noted:

- **10a same-work compare** — instruction-lockstep the icache-off and icache-on SoCs over
  the identical post-handoff instruction stream (the honest number; a fixed-cycle window
  conflates program phases): **5.94×**, 93.5% hit-rate on the 28.8K-instr aligned prefix.
- **Stall profile** — every system clock bucketed (retire / exec / compute / fetchW /
  loadW / storeW) with a video-contention overlay, segmented per 250k instructions. It
  runs the **shipped policy** (write-update since 10b landed — a lesson in itself: the
  10a-policy profile kept showing loadW 21.6% long after write-update had already
  eliminated it). True verdict at 10b: CPI 1.75, 25.0% of clocks frozen — **storeW 22.1%
  (88% of frozen)**, read-wait 3.0%, video overlay 5.0% (22.8% port occupancy); the
  write-buffer ceiling there **1.28×** at 2.6× bus-free headroom.
- **`?video` A/B** — gating `vidreq` at elaboration removes video from the PSRAM port =
  the framebuffer-in-BRAM counterfactual. On the write-update baseline the same-work
  ceiling is **1.180×** (the earlier 1.228× was measured against the 10a policy — a
  slower machine overlaps video more).
- **Miss autopsy** — an OCaml (valid, tag) mirror of the cache, validated **0-mismatch
  against the RTL's own `cache_hit` over boot + 2M instructions**, classifies every miss
  and replays counterfactual snoop policies on the same access stream. Verdict: **96.1%
  of load misses were snoop-invalidate self-inflicted** (store-then-load stack traffic) —
  which became Phase-10b write-update (landed: load hit 58.7→98.4%, same-work **1.305×**,
  measured by the lockstep A/B in the same run). Write-allocate measured not worth it.
- **Load-locality sweep** — per-size fetch/load hit-rates, 1 KB→256 KB: capacity-flat
  (+1.6 pt), which is what pointed at policy rather than size.
- **10c framebuffer-in-BRAM, measured** (Phase-10c landed) — the same-work lockstep of
  PSRAM-video vs the `Framebuf` shadow (`?fb_bram`): **1.180×, exactly the gating
  ceiling** — the shadow's 1-cycle BRAM read never touches the CPU's clock-enable, so
  the fb-bram cycle count is identical to the `?video:false` counterfactual's. The
  shadow-ON profile gave the 10c residual: **CPI 1.64**, frozen 19.9%, storeW 18.3%
  (92% of frozen), video occupancy/contention 0 — write-buffer ceiling from there
  **1.22×** at 4.4× bus-free headroom.
- **10d write buffer, measured** (Phase-10d landed) — the same-work lockstep of
  synchronous stores vs the 1-entry buffer (`?write_buffer`): **1.237×** (CPI 1.90→1.53
  over a 126.8K-instr aligned prefix — above the 1.22× ceiling estimate, which priced
  misses off a different stream). The wbuf-ON profile gave the depth-1 residual: CPI
  1.45, frozen 9.5% — storeW 7.5% slot-full burst waits (deeper-FIFO ceiling **1.08×**)
  + read-wait 2.0% (of which drain-before-read costs +0.4% — the conservative hazard
  rule, priced and kept).
- **10d follow-up: depth-2 FIFO + the rc=6 margin trade, measured** — the depth-1 vs
  depth-2 lockstep (`?wbuf_depth`): **1.066×**, near the 1.08× ceiling (the burst waits
  were Oberon's 2-store procedure prologues, as hypothesised); CPI 1.45→**1.36**, storeW
  →1.7%, and the ceiling from there is **1.02×** — depth 3+ is measured dead. The rc5 vs
  rc6 lockstep prices the PSRAM I/O margin trade (`read_cycles:6` after the 13.3 ns
  budget failed once and grazed twice in synthesis): **0.86%** — only the ~0.3%-of-
  accesses miss classes pay +2 cycles. Shipped baseline: **CPI 1.37**, frozen 4.2%. Arc
  trajectory, long windows: CPI 26.28 → 2.16 → 1.75 → 1.64 → 1.45 → **1.37**.

Four harness lessons, so they're not relearned: **video DMA is live in every board sim**
(Cyclesim's one-domain semantics advance the pclk raster 1:1 regardless of the `pclk`
input level — hold-pclk-low does *not* quiet it; use the `?video` seam); **make probe
lookups loud** — `cr_busy`/`cr_op_vid` are registers, invisible to `lookup_node_by_name`,
and the silent `None` zeroed the contention overlay on its first run; **dead-code
elimination eats unobserved probes' *logic*** — with only `sclk` in `Board_tb.O`, Cyclesim
pruned the whole pixel path *including the `fb*` shadow BRAMs*, and the golden's
`lookup_mem_by_name "fb0"` found nothing; `Board_tb` now exposes `hsync`/`vsync`/`rgb` to
keep the path live; and **`Cyclesim.outputs` samples *after* the clock edge by default**
— `after(k) = before(k+1)`, so register-driven completions just read one iteration late,
but an input-driven pulse like the write buffer's accept `ce` is invisible there (its
first measurement read "6 cycles" for a 1-cycle store); the core's view is
`~clock_edge:Before`, which the wbuf tests sample.

## Notes

- All three are opt-in (built by `@check` so they can't rot; run by alias). `@bench_boot`
  now carries the whole Phase-10 gauge suite — a dozen boots of the PSRAM SoC plus several
  2M-instruction windows through the interpreter, ~20–25 minutes end to end.
- Numbers above are from this sim harness (behavioural `Cellram_model`, `read_cycles` as
  noted). They're for *ratios and Amdahl context*, not absolute wall-clock — the point is
  which lever moves the needle, and by how much.

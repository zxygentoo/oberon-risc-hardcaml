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
Boots the real memory path — `Soc_board` (core on a clock-enable, main memory behind
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
  loadW / storeW) with a video-contention overlay, segmented per 250k instructions.
  Verdict at 10a: CPI 2.16, 39.3% of clocks frozen on PSRAM — loadW 21.6%, storeW 16.1%,
  video overlay 9.0% (22.7% port occupancy). Plus the write-buffer ceiling (storeW fully
  hidden = **1.19×**, ≥2.9× bus-free headroom).
- **`?video` A/B** — gating `vidreq` at elaboration removes video from the PSRAM port =
  the framebuffer-in-BRAM counterfactual: same-work **1.228×** ceiling.
- **Miss autopsy** — an OCaml (valid, tag) mirror of the cache, validated **0-mismatch
  against the RTL's own `cache_hit` over boot + 2M instructions**, classifies every miss
  and replays counterfactual snoop policies on the same access stream. Verdict: **96.1%
  of load misses were snoop-invalidate self-inflicted** (store-then-load stack traffic) —
  which became Phase-10b write-update (landed: load hit 58.7→98.4%, same-work **1.305×**,
  measured by the lockstep A/B in the same run). Write-allocate measured not worth it.
- **Load-locality sweep** — per-size fetch/load hit-rates, 1 KB→256 KB: capacity-flat
  (+1.6 pt), which is what pointed at policy rather than size.

Two harness lessons, so they're not relearned: **video DMA is live in every board sim**
(Cyclesim's one-domain semantics advance the pclk raster 1:1 regardless of the `pclk`
input level — hold-pclk-low does *not* quiet it; use the `?video` seam), and **make probe
lookups loud** — `cr_busy`/`cr_op_vid` are registers, invisible to `lookup_node_by_name`,
and the silent `None` zeroed the contention overlay on its first run.

## Notes

- All three are opt-in (built by `@check` so they can't rot; run by alias). `@bench_boot`
  boots the PSRAM SoC three times through the interpreter (~a minute or two).
- Numbers above are from this sim harness (behavioural `Cellram_model`, `read_cycles` as
  noted). They're for *ratios and Amdahl context*, not absolute wall-clock — the point is
  which lever moves the needle, and by how much.

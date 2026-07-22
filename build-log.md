# Build log — Oberon RISC5 → Hardcaml

The phase-by-phase build log, moved out of `AGENT.md` (2026-07-22) once the build was
complete. `AGENT.md` is the working manual; this file is the record — what each phase
delivered, how it was proven, what was measured, and the design narratives of the three
optimization arcs (compute, memory, display).

Section references like §2/§6/§8 point into `AGENT.md`. Deeper detail lives next to the
code: `board/nexys-4/README.md` (board bring-up log), `test/formal/README.md` (proof
inventory), `test/bench/README.md` (measurement gauges), `test/cosim/README.md`, and the
DOOM repo's `ABI.md`/`DOOM.md`.

---

## Overview

Phases 0–6 are board-independent, fully verified in simulation; Phase 7 is the only
Vivado-specific layer; 8 closes the formal proofs; 9–11 are the optimization arcs.

| Phase | Landed | Proven by |
|---|---|---|
| 0 | dune scaffold on ox; `emu` wrapper; FP vectors + boot ROM | smoke test |
| 1 | `LeftShifter`, `RightShifter`, ALU + C/V flags | unit specs / qcheck |
| 2 | Register file (3R/1W async-read array) | unit tests |
| 3a | `Multiplier`, `Divider` (33-cycle, stall) | qcheck vs OCaml reference |
| 3b | `FPAdder` / `FPMultiplier` / `FPDivider` | FP vectors + fuzz + RTL co-sim |
| 4 | CPU core (`RISC5.v`) | single-instruction lockstep |
| 5 | Sim SoC + SPI/SD → OS handoff | boot-handoff checkpoint |
| 6a | UART, PS/2 kbd, mouse, video | co-located tests + RTL co-sim |
| 6b | SoC top (MMIO map + video DMA) | visual golden |
| 7 | Board layer → **boots on real silicon** | on-hardware boot |
| 8 | Formal equivalence, 17 checks | yosys `equiv_induct` / z3 |
| 9 | Compute arc: DSP muls, **60 MHz** | differential qcheck + lockstep + benches |
| 10a–d | Memory arc: I-cache → write buffer, CPI 26.28 → **1.37** | same-work locksteps + goldens + hardware |
| 11 | Display arc: `Halftone`, DOOM **14.1 fps** | 4-rung differential + golden + silicon |

---

## Phases 0–3 — scaffold and datapath units

- **0 — scaffold.** dune project on the ox switch; emulator submodule + the `emu`
  wrapper library; FP vectors & boot ROM via the submodule; waveterm rendering exercised
  in a smoke test (retired once the real suite subsumed it).
- **1 — shifters + ALU.** `LeftShifter`/`RightShifter`, ALU logic/adder with C/V flags.
  Unit specs / qcheck.
- **2 — register file.** 3R/1W async-read array (`RAM16X1D` re-inferred, not
  instantiated). Unit tests.
- **3a — MUL/DIV.** Iterative, state counter + `stall`, 33 cycles. qcheck vs a
  pure-OCaml integer reference (signed/unsigned 64-bit `*`, floored `/`);
  hardware-accurate, including the §8 unsigned-`MUL` corner.
- **3b — FP units.** `FPAdder`/`FPMultiplier`/`FPDivider` (+ FLT/FLOOR).
  Reachable-domain `fp_vectors.txt` replay + `Emu.Fp` fuzz + RTL co-sim vs the `.v`
  (`test/cosim/`).

---

## Phase 4 — the CPU core

- **Landed:** PC/IR + control unit + stall aggregation + interrupts + N/Z (from
  `regmux`) — the glue around the Phase 1–3 units.
- **Proven by:** single-instruction lockstep vs `Emu.Risc.For_tests.single_step`,
  qcheck-fuzzed, steering around the §8 divergences.
- The interrupt FSM has no oracle (the emulator is interrupt-free): verified by a
  behavioural waveform vs `RISC5.v`, then exhaustively by the Phase-8 core proof and the
  boot-stream co-sim.

---

## Phase 5 — sim SoC + SD boot

- **Landed:** memory + SoC harness + the SPI/SD-card master (the one peripheral boot
  needs); boots the ROM through the SD load to the **OS handoff** (`pc=0`).
- **Proven by:** the boot-handoff checkpoint — the SoC's SD card driven from the same
  `Emu.Disk` + `.dsk` the emulator boots; loaded image + architectural state compared at
  the handoff (~403 K instructions, ~21 K SPI transactions). Plus SoC integration unit
  tests.
- Runs on the plain Cyclesim interpreter; opt-in as `dune build @boot_checkpoint` (§6).

---

## Phase 6 — peripherals and the SoC top

### 6a — the remaining peripherals

- **Landed:** UART (`RS232R`/`RS232T`), PS/2 keyboard (`PS2`), PS/2 mouse (`MousePM`),
  video controller (`VID`, framebuffer DMA) — each a faithful port.
- **Proven by:** per-module co-located `ppx_expect`/`qcheck` + Verilator RTL co-sim vs
  the `.v` — the proven Phase 1–5 stack.
- Notable mechanics:
  - VID is two-clock (`By_input_clocks`; the DCM→pclk becomes a Phase-7 input);
  - the mouse splits its open-drain `inout` into `*_oe` outputs + resolved inputs;
  - closed with the cosim-harness dedup — a shared `run_serial_cosim` across
    SPI/RS232x/PS2 (+ the rename to `cosim.h`).
- Tooling verdict: `hardcaml_step_testbench` + `event_driven_sim` evaluated (twice,
  through the mouse) and **rejected** — the device model is a single sequential task, so
  the coroutine gave no benefit while running ~5× slower.

### 6b — the SoC top

- **Landed:** the full `RISC5Top` MMIO map (UART 2/3, mouse + kbd 6/7, GPIO 8/9, LEDs +
  switches 1) + the video DMA / `stallX` path; framebuffer out.
- **Proven by:** the **visual golden** — boot past the handoff to the idle Oberon
  desktop, framebuffer byte-identical to the emulator (hash `0xb9bdbf56ba51298d`,
  18607 px; `dune build @visual_golden`).
- **The bug it caught** — a real core bug the single-instruction fuzzer structurally
  missed:
  - ADD/SUB set the flags from `op` alone, lacking `RISC5.v`'s `~p` — so a *stalled*
    conditional branch whose op-field is 8/9 clobbered C → a spurious trap ~17.3 M
    cycles into the boot;
  - caught + root-caused by a new **boot-stream RTL co-sim**: capture the core's
    per-cycle I/O over the boot, replay through `RISC5.v` under Verilator, report the
    first divergence — now the `core` unit of `dune build @cosim`, the core's first
    cycle-level RTL check;
  - fixed (one `~p`) and guarded in the fast suite (the ALU qcheck drives `p`; the
    lockstep branch-gen reaches op-field 8/9).

---

## Phase 7 — the board layer: first silicon

- **Landed:** MMCM, `IOBUF`/`ODDR`, the Cellular-RAM (PSRAM) async-SRAM adapter,
  VGA/PS2/SD pins, the `.xdc` → a bitstream. The Phase-6 design ports **nearly
  unchanged** onto the Nexys 4 and **boots Project Oberon to the idle desktop from an SD
  image on real silicon**.
- **Timing:** post-route WNS 9.389 ns (pixel domain) / 20.992 ns (clk25 domain), all
  constraints met.

### The flicker bug — the formal layer's flag come true

- Symptom: horizontal video flicker on hardware. Cause: VID's framebuffer-fetch **CDC**
  — the one spot Phase 8 had already flagged as not cycle-equivalent to `VID60.v`.
- The Phase-6 `caught`/`req` handshake sampled a `pclk` flop directly in `clk` with no
  synchroniser (+ a clk→pclk feedback) — deterministic in simulation,
  metastable/timing-marginal on silicon.
- Fix, two parts:
  - a metastability-safe **toggle pulse-synchroniser** (`lib/video.ml` `pulse_sync` —
    proven no-loss/no-spurious for all phases in Phase 8; cosim + visual golden confirm
    it's output-identical);
  - matching `.xdc` CDC constraints (`set_clock_groups -asynchronous` clk25↔clk65 +
    `ASYNC_REG` on `sync0/1/2`). A `set_max_delay -datapath_only` on the
    `req_toggle→sync0` hop is deliberately *not* used: clock_groups outranks it in
    Vivado (rendering it inert), and the routed hop is already ~0.95 ns — see the
    `nexys4.xdc` note.
- Confirmed gone on real hardware, both PO and EO.

### PS/2 topology (swapped 2026-07-11)

- A **genuine 3-button PS/2 mouse** sits on a Digilent Pmod PS/2 in JA's top row
  (msClk=D17 / msDat=B13) — the *bidirectional* device, so the open-drain IOBUFs live
  there; middle-button interclicks work.
- A **USB keyboard** sits on the onboard USB-HID port (PS2Clk=F4 / PS2Data=B2) — the
  PIC24 bridges it to an emulated PS/2 device; our `PS2` is receive-only, so plain
  inputs.
- The direction machinery follows the **device role**, not the connector. Both confirmed
  on hardware (keyboard first brought up on the Pmod 2026-07-07, then swapped; the
  controllers were already proven in `@formal` + cosim, so each step was pure board
  wiring).
- Bring-up facts:
  - the PIC has **no USB-hub support** — composite/hub keyboards (passthrough ports,
    wireless combo dongles) never enumerate; plain HID boards work;
  - after a **JTAG** load the mouse needs one btnCpuReset (config-time pin float
    disturbs the one-shot init); QSPI cold boot is clean.
- Full detail: `board/nexys-4/README.md` "PS/2 topology".

---

## Phase 8 — formal equivalence

Prove (not sample) the port equivalent to the reference `.v` — the exhaustive form of
the RTL co-sim. All in `test/formal` (`@formal`); full inventory + soundness arguments
in `test/formal/README.md`.

### The harness — two modes

- **Combinational:** `hardcaml_of_verilog` imports the `.v` to a circuit (yosys),
  `hardcaml_verify`'s `Sec` SAT-checks it against ours (z3). Needs only matching *port*
  names.
- **Sequential:** `Sec` can't pair the imported registers, so instead we *emit* our
  Verilog and prove inside yosys — `equiv_make` pairs flip-flops **by name** →
  `equiv_induct`, *unbounded* temporal induction (all states, not a bounded trace).
  Needs the *register* names to match the RTL — which is why lib registers keep them.
- Every yosys proof is one `Yosys_equiv.run_proof` driver filling a checked-in
  `.ys.template` under `test/formal/proofs/` — the proofs differ only in their template
  + a few subst values.

### What's proven

- **Datapath units:** both shifters (z3); Multiplier, Divider, and all three FP units
  (yosys) ≡ their `.v`.
- **Register file** — the one unit proven against a *behavioural spec*
  (`registers_spec.v`: 16×32, 3 async reads, 1 sync write) instead of `Registers.v`:
  - its 64 duplicated bit-sliced `RAM16X1D` primitives are a synthesis idiom whose state
    (1024 bits vs our array's 512) is structurally incongruent — nothing for
    `equiv_make` to pair, and a memory miter isn't inductive on outputs alone (only a
    shallow bounded check is tractable);
  - both sides being one array, the script's `memory` pass lowers them to flip-flops
    that pair by name, and `equiv_induct` closes;
  - that `RAM16X1D` meets the same contract is Vivado's distributed-RAM inference, not
    ours (§2/§3 — the regfile is the canonical "structure is not the spec").
- **The core glue, incl. the in-situ ALU** (`aluRes` is inline in `RISC5.v`; our `Alu`
  is a refactored grouping — folds `C0`→`c1`, zeroes the other units' op slots — not an
  RTL slice) — proven ≡ `RISC5.v` with the 8 submodules black-boxed, assume-guarantee
  style:
  - `Cpu.create_with_units` is the seam; `Core_blackbox` feeds it `Instantiation` stubs
    with names matched to the RTL;
  - `equiv_make` merges the matched unit cells (checking their *inputs* via the `$equiv`
    on the named nets), `cutpoint -blackbox` cuts the merged units' *outputs* to shared
    free signals, and `equiv_simple`/`equiv_induct` close the glue;
  - sound because no combinational path crosses a submodule boundary (the core
    decomposes into glue + proven leaves); teeth-checked — mutating a glue constant
    leaves exactly the affected `$equiv` unproven.
- **Tier-1 peripherals:** RS232R/T, SPI, PS2 ≡ their `.v` — clean single-clock FSMs as
  `sequential` rows; each lib register *named*, then paired to the RTL by a per-row
  `renames` list (e.g. `q0→Q0`, `spi_shreg→shreg`); SPI's `rdy` `output reg` pairs via
  the output port; PS2's 16×8 `fifo` pairs through the `memory` pass like the register
  file.
- **Mouse** (Tier 2) ≡ `MousePM.v`, through the open-drain `inout`→split-port shim:
  - two shims wrap *both* sides into one explicit interface with a **free** external
    read — else yosys ties the inout read to 0 and the FSM degenerates into a vacuous
    proof;
  - the observable is the resolved line `oe ? 0 : ext`; the tristate is lowered by
    `tribuf -formal` / `chformal -remove` / `setundef -one` (the pad pull-up).
- **VID** (Tier 2) ≡ `VID60.v` — a *partial* multiclock proof:
  - drop `VID60.v`'s DCM (a Phase-7 primitive) + `expose -input pclk`;
  - **cut** `vidbuf` to a shared free input, so the raster + pixel datapath prove ≡
    `VID60.v` *given the fetched word*;
  - **`equiv_remove`** the `req` handshake — the framebuffer-fetch CDC deliberately
    departs (our toggle pulse-synchroniser vs the RTL's async-set `req1`).
- **The CDC departure, closed by a property proof** (`vid_invariant`): the extracted
  `pulse_sync` primitive proven **one `req` per `req0`, no loss, no spurious — for all
  clk/pclk phases and all reachable states**, via `yosys-smtbmc -i`/z3 **k-induction**
  (the engine SymbiYosys wraps — no `sby` needed, and no hand-crafted inductive
  invariant: k≈48 spanning a fetch cycle suffices). The CDC-robustness a single-phase
  Cyclesim test can't reach.
- **The 2-group prefetch's `vidadr` departure, closed by decomposition:** the look-ahead
  address proven ≡ an independent geometry spec (`vid_addr`, combinational `Sec`/z3, all
  `(hcnt,vcnt)`); timing comes from `vid_invariant`; a **reviewed composition lemma**
  glues them — the one place a hand argument bridges the mechanized pieces (the
  monolithic all-phases proof doesn't converge: col 0 is cross-line; see
  test/formal/README "VID prefetch").

### Tally & scope

- **17 checks, every one mutation-checked.**
- Out of scope: the SoC top (`RISC5Top`) — board-specific; our sim `Soc` ≠
  `RISC5Top.OStation.v` by design (DCM/PROM/IOBUF/memory are Phase-7 concerns).
- Postscript: the VID-CDC departure was no longer just a sim artifact — its `caught`
  one-shot turned out to be a real metastability bug on the Nexys 4 (the Phase-7
  flicker), so `video.ml` now ships the synchroniser the proof is built around. **The
  formal layer flagged the exact fragile spot.**

---

## Phase 9 — the compute arc

*Correct before fast.* Phases 0–8 hold the cycle-accurate mandate (§2), which keeps
`RISC5.v` a *total* oracle — a bright line that keeps the spec unambiguous and bugs
findable. Phase 9 is the one place we deliberately cross it, only *after* the faithful
port is verified (and formally checked in 8): optimizations are judged against the
**ISA/oracle** — does Oberon still boot and lockstep at the instruction level — not
against `RISC5.v` timing. Work from a tagged faithful baseline, so the proven port is
never lost.

### DSP multiplier (`?fast_mul`)

- The iterative 33-cycle `Multiplier` becomes swappable for a **combinational
  DSP-backed** `Multiplier.create_opt`: the same 32×32→64 multiply as one signed 33×33
  `*+` (the §8 sign handling preserved: `y` always signed, `x` signed iff `u`), which
  Vivado lowers onto **4 DSP48E1** slices.
- Rides the existing `Cpu.Units` seam, selected by `?fast_mul` (default `false`),
  threaded `Cpu.create` → the board/sim `Soc.create`s → `emit_verilog` (only the board
  emit opts in).
- Proven **bit-identical** to the faithful `create` by a co-located differential qcheck
  (20k cases, full 64-bit `z`) — it rides `create`'s Phase-8 proof transitively, *not*
  re-formalised.
- Results: per-MUL cost 34→2 core cycles (`@bench`); synth infers the 4 DSP48E1 and
  **50 MHz closes** (WNS +1.521 ns — the combinational MUL is now the critical path,
  `regfile → 2×DSP48E1 cascade → result`; a DSP48E1 `MREG`/`PREG` pipeline stage is the
  free fix if the clock ever passes ~54 MHz).
- On hardware: boots Oberon to the desktop and **rebuilds the entire Extended Oberon
  system with no traps**. The default core stays byte-identical — all Phase 0–8 gates
  green with the seam inert at `fast_mul=false`.

### DSP FP multiplier

- The same flag swaps `Fp_multiplier.create_opt`: `FPMultiplier.v`'s 24-iteration
  mantissa loop as one unsigned 24×24 `*:` (→ DSP48), reusing the exponent/round wrapper
  (factored into a shared `pack`) verbatim — so bit-exactness again reduces to
  "same `P`".
- Proven by its own differential qcheck (20k cases) against the formally-proven
  iterative unit; `@formal` still closes `create ≡ FPMultiplier.v` after the `pack`
  refactor.
- Results: **6 DSP48E1** total (4 integer + 2 FP); 50 MHz still closes (WNS +0.897 ns —
  the FP multiply, `regfile → 2×DSP48E1 → round → reg`, now the tightest path); boots
  Oberon clean to desktop on hardware.
- Remaining: DIV and `FPDivider` stay iterative — division has no DSP primitive; the
  real win is Newton-Raphson (reciprocal refinement *using* these DSP multipliers), a
  genuine algorithm change with delicate bit-exactness — a deferred project, not
  low-hanging like the two multiplies.

### The 60 MHz build

- `Multiplier.create_opt_pipelined` / `Fp_multiplier.create_opt_pipelined` add `?stages`
  registers on the DSP product that Vivado retimes into the DSP48 `MREG`/`PREG` — the
  multiply moves *off* the critical path, and the system clock reaches **60 MHz**
  (`mul_stages:2`; MMCM VCO 780, WNS +0.9 ns; the new limiter is the FPAdder
  normalize/round).
- The pipelined core is lockstep-checked (a `~fast_mul ~mul_stages:2` run of
  `test_cpu_lockstep` — the units are already differential-qcheck'd, so this pins the
  2-cycle-stall integration under the real core's driving).
- A companion UART-baud parameterization (`RS232R/T ?baud_slow/?baud_fast`) keeps the
  wire at a standard rate off the 60 MHz clock (115200 default, ~5× serial-read
  throughput); the faithful 25 MHz constants would give 46083 baud. Boots clean on
  hardware.

### The verdict (benchmarked, `test/bench/`)

- MUL is **34→2 cycles (17×)** per op (`@bench`) — but only **0.1% of executed
  instructions** (`@profile_boot`), an Amdahl ceiling of ~3.3% — so **+0.00%
  end-to-end** on a boot (`@bench_boot`: faithful vs `fast_mul` identical to the cycle).
- Meanwhile **~24% of boot cycles are PSRAM wait** — and that *understates* the running
  OS: boot fetches code from the on-chip ROM fast-path; the OS fetches every instruction
  from PSRAM.
- The broad win actually banked: the **50→60 MHz clock, 1.2×**, on compute and memory
  alike.
- **The compute arc is done** — the DSP multipliers were right to build (free once the
  DSP48s are placed, and they *enabled* the clock bump), but further multiply/clock work
  is Amdahl- or memory-capped. The next lever is memory. See `test/bench/README.md`.

---

## Phase 10 — the memory arc

The Phase-9 benchmark pointed here unambiguously: the machine is **memory-bound** —
every OS instruction fetch is a multi-cycle PSRAM read, so the leverage is cutting
memory latency, not adding compute. Four steps, each measured before built. Running-OS
CPI across the arc: **26.28 → 2.16 (10a) → 1.75 (10b) → 1.64 (10c) → 1.45 (10d) → 1.37
(shipped, depth-2 + rc=6)**.

Verification throughout is Phase-9 style — judged against the ISA/oracle, not `RISC5.v`
timing (a cache is a new architectural block, not in the faithful RTL) — and every step
closes with: a same-work pc-lockstep A/B, co-located unit tests, the board visual golden
with the feature ON, and an on-hardware boot.

### 10a — the I-cache

- **What:** a direct-mapped, write-through read/I-cache (`board/nexys-4/cache.ml`,
  default 1024 one-word lines = 4 KB) in front of `Cellram` — in the **board layer**,
  never `lib/`, so the core stays byte-identical and its Phase-8 proof untouched (the
  latency it fights is a board phenomenon; the lib sim has single-cycle memory).
- **Design choice 1 — 0-stall combinational hit:**
  - the tag/data array is async-read distributed RAM (`multiport_memory` — exactly the
    register-file idiom; BRAM can't read combinationally);
  - on a hit the board `Soc` drops `mem_pend`, so `Cellram`'s `ce = ~mem_pend | …` rises
    the *same* cycle and the word muxes from the cache — zero stall cycles, no new pipe
    stage, no core change;
  - synthesises to `RAMS64E` LUTRAM (720 LUT distributed, **0 BRAM**); the *fill* path
    (`pc_reg → icache_mem write` ≈ 15.6 ns) becomes the new critical path — the register
    file's async-read twin.
- **Design choice 2 — coherence with no flush op** (Oberon has none — the real machine
  has no cache). One invariant: *a valid line always equals PSRAM* — fills copy PSRAM,
  the cache issues no writes itself (write-through), and a CPU store **snoops**,
  invalidating a matching line. The three cases:
  - CPU→CPU — incl. the module loader writing code then jumping into it (the case that
    would otherwise trap the OS);
  - CPU→video — write-through keeps the framebuffer live for the video DMA's own,
    never-cached read port;
  - video→CPU — read-only, nothing to snoop.
  - The invariant holds *continuously*, so no reset-invalidate is needed: the LUTRAM
    powers up `INIT=0` (all lines invalid) at configuration.
- **Results:** **~6× on running-OS code** (93% hit-rate), +5% through boot (already
  ROM-fast-pathed); boots clean, "runs way smoother" on hardware; 60 MHz still closes.
- **Proven by:** the `@bench_boot` same-work lockstep (off vs on — the honest number,
  not phase-drifted throughput), `@visual_golden_board` byte-identical with the cache ON
  (a full coherence proof), the 28.8K-instruction pc-lockstep it rides on, and
  co-located fill/hit/snoop-invalidate tests.

### 10b — write-update snoop

- **The problem:** 10a left running-OS CPI at 2.16 with 39.3% of clocks frozen on PSRAM
  — and the biggest bucket, load-wait (21.6%), was self-inflicted: the snoop
  *invalidated* on every store-hit, so Oberon's store-then-load stack discipline
  re-bought a ~20-cycle PSRAM read per procedure frame.
- **The measurement — the miss autopsy:** an OCaml (valid, tag) mirror of the cache,
  validated **0-mismatch against the RTL's own `cache_hit` over boot + 2M
  instructions**, then replaying counterfactual snoop policies on the same access
  stream:
  - **96.1% of load misses were store-killed**;
  - the capacity sweep was flat (1 KB→256 KB moved the hit-rate 1.6 pt) — no cache size
    would fix it.
- **The fix — one mux:** on a **word store-hit, rewrite the line as
  `{valid, tag, wdata}`** through the same write port instead of zeroing it
  (`Cache ?write_update`, default off = the proven 10a policy). Coherence unchanged:
  - the update happens in the same write-through transaction that lands the identical
    word in PSRAM; the ce-frozen core can't read mid-store; video never reads the cache;
  - byte stores still invalidate (merging one lane needs read-modify — and the measured
    byte-store count was zero).
- **Results:** load hit **58.7 → 98.4%** (residual misses 90% genuine conflicts);
  **1.305× same-work** (CPI 4.39→3.36 over the 29.1K-instr aligned prefix); long-window
  CPI 2.16→**1.75**; WNS +0.708 ns at 60 MHz (the cache-write path ate ~0.2 ns for the
  deeper `wd` mux — now the frequency limiter); boots clean, runs visibly smooth.
- **New measurement layer** (`test/board/nexys-4/bench_boot.ml`; index
  `test/bench/README.md`):
  - the running-OS **stall profile** — every clock bucketed
    retire/exec/compute/fetchW/loadW/storeW, plus a video-contention overlay;
  - the **`?video` A/B seam** — an elaboration-time gate on `vidreq`, the honest
    framebuffer-in-BRAM counterfactual (at this point: 1.228× ceiling, 22.7% port
    occupancy, 9% contention overlay);
  - the **miss autopsy** above.
- **Lessons banked** (now §6 "Cyclesim gotchas"): video DMA is live in *every* board sim
  (one-domain Cyclesim advances the pclk raster 1:1 regardless of the pclk input — the
  old "pclk held low = no video" comment was wrong); silent `lookup_node_by_name`
  failures zero out probe columns (`cr_busy`/`cr_op_vid` are registers, reachable only
  via `lookup_reg_by_name` — make unconditional lookups loud).

### 10c — framebuffer-in-BRAM

- **Measure first:** threading the *shipped* policy through the stall profile
  (`?write_update` — a one-flag bench fix) corrected the residual picture — loadW 21.6%
  was *already gone* (an artifact of profiling the 10a policy after 10b landed). The
  true 10b residual: CPI 1.75, 25.0% frozen — **storeW 22.1% (88% of frozen)** — video
  tax 22.8% port occupancy / 5.0% contention; gating ceiling re-measured **1.180×** (the
  1.228× on record was vs the 10a policy).
- **The build** (`Framebuf`, `board/nexys-4/framebuf.ml`): the framebuffer **shadowed in
  on-chip BRAM** — the cache's coherence trick applied to the video window:
  - *write-through shadow; PSRAM keeps the truth.* Every PSRAM-bound store in the
    DMA-addressable span `[Video.org, Video.org+0x8000)` (the *full* 32768 words
    `Video.lookahead` can address — no blanking-time assumptions; `Video.org` newly
    exported, one constant, no drift) also writes the shadow in the same write-through
    transaction ⇒ **shadow ≡ PSRAM window at every instant** (both power up zero; the OS
    paints the screen before showing it). CPU *loads* untouched.
  - *video reads the shadow, 1 cycle.* Four byte-lane 32768×8 **sync-read** BRAMs (the
    `lib/ram.ml` byte-enable idiom; sync read is what infers *block* RAM — the cache's
    async-LUTRAM idiom would burn ~26k LUTs here) answer a fetch with `vid_ack` the next
    clock, through `Video`'s existing `?viddata_valid`/`?viddata_par` seams — `Video`
    itself unchanged. `Cellram`'s `vidreq` ties low ⇒ its video FSM + read-preemption
    logic prune at synthesis.
- **Results:** same-work **1.180× — exactly the gating ceiling** (the fb-bram cycle
  count is *identical* to the `?video:false` counterfactual's: the shadow read never
  touches `ce`); long-window CPI 1.75→**1.64**; video port occupancy/contention → **0**;
  **32 RAMB36** (the design's first BRAM use, 23.7% of 135), 720 LUTRAM unchanged, WNS
  +0.213 ns (critical path still the cache write); boots clean, desktop smooth.
  Residual: storeW 18.3% (92% of frozen); write-buffer ceiling from here **1.22×** at
  4.4× bus-free headroom.
- **Proven by:** the `?fb_bram` same-work lockstep (29.1K instrs), `Framebuf`'s
  co-located tests, and `@visual_golden_board` with `FB_BRAM=1` — byte-identical desktop
  *read from the shadow*, plus a direct assert that **all 32768 shadow words equal the
  PSRAM window**.
- **Lesson banked** (§6): Cyclesim dead-code elimination eats unobserved logic — with
  only `sclk` in `Board_tb.O`, the whole pixel path *including the shadow BRAMs* was
  pruned and `lookup_mem_by_name "fb0"` found nothing; `Board_tb` now exposes
  `hsync`/`vsync`/`rgb` to keep the observed path live.

### 10d — the write buffer

- **The residual:** post-10c, almost all store-wait — storeW 18.3% of clocks, 92% of
  frozen; ceiling 1.22× at 4.4× bus-free headroom.
- **The build:** a 1-entry write buffer inside `Cellram` (`?write_buffer`, default off;
  the board pairs it with `fb_bram`):
  - a PSRAM store retires in **one `ce` cycle** — the slot captures `{adr, ben, wdata}`
    whenever it is free, even mid-video-op (`wb_accept` joins the `ce` equation);
  - the write **drains in the background** as an `op_wb`-tagged op riding the machinery
    the controller already had — excluded from the CPU's `ce` exactly as video ops are,
    and exempt from video preemption because it *is* a write.
- **Hazards, closed conservatively then measured:**
  - *drain-before-read* — a PSRAM read (a cache miss) waits out a pending drain, so
    every PSRAM read sees fully-drained memory: no forwarding, no address compare.
    Measured cost +0.4% of clocks (read-wait 1.6→2.0%) against misses that are ~0.3% of
    accesses — the right trade;
  - a second store while the slot is full waits frozen — the burst cost, measured at
    **7.5% of clocks** residual storeW, which prices the next lever (a deeper FIFO's
    whole remaining ceiling: **1.08×**, CPI 1.45→1.34);
  - ordering: MMIO/ROM accesses still complete in one cycle *during* a drain, so an MMIO
    store can become visible before an earlier buffered RAM store lands — benign here
    (no peripheral reads RAM; video reads the `Framebuf` shadow, never PSRAM). Coherence
    untouched: cache snoop/update and the shadow write happen at store *retire*, and
    drain-before-read means PSRAM catches up before anyone can look.
- **Results:** same-work **1.237×** (CPI 1.90→1.53 over a 126,784-instr aligned prefix —
  above the 1.22× ceiling estimate); long-window CPI 1.64→**1.45**; frozen
  19.9%→**9.5%**.
- **Synth:** the stock flow *failed* timing — `RamUBn` missed the 6.7 ns PSRAM I/O
  output budget by 0.163 ns, pure placement (3.3 ns of route; the byte-enable cone is
  untouched by the buffer) — closed by **Explore-class implementation directives** (now
  in `build.tcl`, with the structural fallback documented: register the byte-enable
  pins); WNS +0.130 ns. Boots clean and compiles fine on hardware.
- **Lesson banked** (§6): `Cyclesim.outputs` defaults to *after*-edge sampling
  (`after(k) = before(k+1)`) — register-driven completions read one iteration late, and
  input-driven pulses like the accept `ce` are invisible; the core's view is
  *before*-edge (`~clock_edge:Before`), which the wbuf tests sample (the first "6-cycle
  store" measurement was this artifact, caught by a per-cycle probe).
- **Proven by:** co-located accept/drain/burst/mid-video tests + a wb-on qcheck
  hammering drain-before-read + the same-work lockstep + the triple-knob golden
  (`FB_BRAM=1 WRITE_UPDATE=1 WBUF=1` — byte-identical desktop + shadow ≡ PSRAM).

### 10d follow-up — the depth-2 FIFO and the rc=6 margin trade

- **Depth-2 FIFO.** The depth-1 residual (storeW 7.5% of clocks, slot-full waits) had
  one obvious shape: Oberon's procedure prologues store in pairs. The slot generalised
  to a `?wbuf_depth` **FIFO** (1..4):
  - slot 0 is the drain source; a completing drain shifts the queue down; the tail
    insert handles the accept-and-complete-same-cycle corner by reading pre-edge values;
  - total store order preserved; drain-before-read waits for the whole queue — the
    coherence argument is depth-independent;
  - depth 1 is **cycle-identical** to the proven slot: the frozen unit expects didn't
    move and every recorded bench gauge reproduced exactly;
  - depth 2, measured: **1.066× same-work** (near the 1.08× all-depths ceiling),
    long-window CPI 1.45→**1.36**, storeW 7.5→**1.7%** — and the ceiling from there is
    1.02×, so **depth 3+ is measured dead**.
- **The rc=6 margin trade.** Landing depth 2 re-squeezed the knife-edge PSRAM I/O budget
  a third time (WNS +0.009 on MemDB-in, after rc=5's 13.3 ns split had already failed
  once and grazed once). Resolved structurally, not with more placer effort:
  - **`read_cycles` 5→6** — the escape hatch the `.xdc` comment had pre-planned. The
    100 ns read phase re-derives the budget 13.3→**30 ns** (split 12/12, ~6 ns true
    slack; write phase stays 5 — its group never pressured, and drains are background);
  - measured cost **0.86% same-work** (only the miss classes pay +2 cycles).
- **Shipped:** CPI **1.37**, 4.2% frozen, WNS +0.169 with the worst path back on the
  familiar internal cache-write path and the I/O groups ~5 ns clear.
- **Proven by:** depth-2 burst/FIFO-order tests + a depth-2 qcheck + same-work
  locksteps (sync vs depth-1, depth-1 vs depth-2, rc5 vs rc6) + the golden re-proven at
  the shipped config (`WBUF=2`, rc=6); boots clean + compiles on hardware at both steps.

### Further levers — measured and deferred

The arc is closed for practical purposes: 4.2% of clocks frozen, and every remaining
lever priced below its noise.

- *Deeper write-buffer FIFO* — depth 3+ remaining ceiling **1.02×**: dead.
- *Burst / page-mode PSRAM fill* — would shorten drains and the ~0.3%-of-accesses
  misses; the whole PSRAM-wait pool is 4.2% of clocks, so the payoff is a fraction of
  that.
- *Dead ends, measured:* bigger/split caches (capacity-flat; residual misses 90% genuine
  conflicts but ~1% of cycles), more compute (0.4–0.6% of clocks), write-allocate
  (+273 hits, evicts fetch lines).

**Workload caveat — the DOOM icache** (feat/more-cache, on-hardware). "Capacity-flat"
above is an **Oberon-OS** fact — its hot loops fit a few KB. The DOOM workload (sibling
`DOOM-on-Oberon`, DOOM.md §1) is the opposite:

- an access-stream replay of the DOOM blob put read-miss stall at **51% of the frame**,
  and it is a *capacity* problem — **55%** of misses are instruction fetch (the renderer
  code footprint), **28%** loads into the 30.7 KB dither rank tables, only **16%**
  zone/texture streaming;
- so the board emit ships a **16 KiB icache** (`emit_verilog.ml` `lines_log2:12`, up
  from the 4 KiB default) — measured **+39% DOOM fps (4.9→6.8)**, closing 60 MHz at
  WNS +0.019 via `build.tcl`'s post-route `phys_opt` recovery loop;
- 32 KiB adds only +4% (16 KiB is the knee); multi-word lines / PSRAM burst fill stay
  the deferred *streaming* lever (only that 16% slice, and each miss would fetch N words
  at full latency without a burst controller). Oberon is unaffected.
- Detail: `board/nexys-4/README.md`.

---

## Phase 11 — the display arc (Halftone)

**Why (the DOOM arc):** post-16 KiB-icache, the software dither was 57% of DOOM's tick —
instruction-bound at its legibility floor. Moving the dither into scanout was fps lever
#3: **8.3 → 12.3 fps on silicon** the day v1 landed, **14.1** held through v2 (with the
DOOM repo's hand-rolled frame copy); timedemo **5026 gametics exact** on the board.

### What it is

**`Halftone`** (né `Indexbuf` — renamed at the merge round: the v1 name described the
storage format, the unit's identity is the transform) — a second display mode in the
board layer:

- a client-defined **8bpp pixel window** (64 KiB himem at `0x310000`; the 10c pattern —
  every PSRAM-bound store in the window also lands in a BRAM shadow, CPU loads
  untouched),
- scanned out to a word-aligned **overlay rect** of the 1024×768 mono panel —
  **ordered dithering (halftoning) at scanout** — through:
  - a **tone LUT** (window +64000),
  - a **64×64 threshold map** (`0x30E000`, values 1..254),
  - a **768-entry row map** (`0x30F000`, `{thr_row, row_base}` — vertical geometry as
    pure table: stride, letterbox, double-buffering are all software),
  - an exact output-driven **horizontal DDA** (`XNUM`/`XDEN`/`XOFF`);
- claim-muxed against `Framebuf` per completing request — outside the rect, or mode off,
  the proven mono path answers untouched.

### Mechanism in hardware, policy in software

- **Hardware keeps only mechanism** — every policy (tone, thresholds, geometry) is
  client-uploaded at runtime.
- v1 baked DOOM's 320×200→fullscreen geometry in ROMs; the generality rework made the
  threshold map writable RAM; **v2 uploaded geometry too** — registers vsync-**shadowed**
  (so `Open` never tears mid-frame), the tables live (rewritten inside the vblank
  window).
- v2 also added a **status word** (vblank flag + frame counter) at MMIO slot 10
  (`0xFFFFE8`) — vblank *detected as a request gap* (Video gates `req0` with `~vblank`,
  so blanking = no requests; found by the first cross-repo `-hw` sim claiming 0/24576
  words).
- Compose FSM: **2 px/clock**, 21 clk/word at any scale. (The 4 px/clock first build
  failed timing at WNS −1.382 on the DDA→pixel-BRAM address chain; halved,
  behaviour-identical, the rebuild closes at **+0.003** — the known icache LUTRAM cone,
  squeezed by v2 congestion from v1's +0.066.)

### Clients & silicon lessons

- Two zero-shared-content clients board-proven — **DOOM** (blue-noise upload; fullscreen
  `RunHW` + the `DOOM.Window` viewer) and **`Mandel.Mod`** (computed Bayer, windowed
  viewer citizen) — with **the desktop live around the rect**.
- Lessons banked from v1 silicon:
  - constant ROMs → **registered initialized arrays**: v1's first bitstream (closed at
    +0.003) *wedged* on DOOM's 16K back-to-back store burst; the array-reg fix rebuilt
    at +0.031 ("unused sequential element removed" warnings are benign cleanup);
  - the scanout window has **no double buffer** — clients render *complete frames* into
    it (DOOM's block-copy contract; renderer-visible-mid-frame flicker is invisible to
    every parked-frame sim leg by construction).
- Design record: the DOOM repo's `ABI.md` §11 (promoted 2026-07-15 from the draft seam
  doc when the mode shipped).

### Proven by

- Four co-located rungs:
  1. DDA ≡ the v1 slot tables (16/5 deals 3/3/3/3/4);
  2. reference model ≡ the gcc-compiled *shipped* `dither.c` over a full frame (hash
     `b66f831b508c374f`);
  3. hardware ≡ model — a **geometry-swept differential** (538 cases on the real ports:
     random rects, scales, row maps; unclaimed fetches assert `claim=0`; shadow-latch
     semantics pinned);
  4. write-path/status pins.
- Mode-off do-no-harm: `@visual_golden_board` with `HALFTONE=1` **byte-identical**.
- Cross-repo: `run_sim -hw` captured scanout (24576/24576 words) ≡ the host golden
  **bit-identical**; on-silicon timedemo 5026 exact at 14.1 fps; both clients
  human-confirmed on hardware.

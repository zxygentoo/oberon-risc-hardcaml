# Oberon RISC5 → Hardcaml

A **cycle-accurate, synthesizable Hardcaml port** of Niklaus Wirth's Project Oberon
**RISC5** machine — the OberonStation FPGA system — targeting a **Digilent Nexys 4
(Xilinx Artix-7 XC7A100T)**, verified in lockstep against an existing OCaml emulator.

The end state: a Hardcaml design that **boots Project Oberon on real silicon**, built up
from the original Verilog one module at a time, with every module proven correct in
simulation before we ever open Vivado.

---

## 0. How we work together (read this first)

**This is a learning project. Speed is explicitly *not* a goal.** The point is for the
human to learn hardware design and Hardcaml deeply. We build this **together — phase by
phase, module by module, step by step.** Optimize for understanding, not throughput.

Concretely, as the agent on this project you should:

- **Explain before building.** For each module: first walk through what the *original
  Verilog* does (its structure, timing, and the hardware idea behind it), then how that
  maps to Hardcaml, *then* write code. Never drop a finished module without the walkthrough.
- **Teach the "why."** Surface the hardware reasoning: why a barrel shifter is staged
  16/8/4/2/1, why MUL takes 33 cycles, what a *stall* physically means, async vs. sync
  RAM reads, combinational vs. registered, fan-out/timing intuition, etc. Treat every
  module as a mini-lesson.
- **Small, reviewable increments.** One module (or even one sub-block) at a time. Prefer
  a short diff the human can fully read over a large code dump. Stop at natural
  checkpoints and let them absorb / ask questions / drive.
- **Don't run ahead.** Do not jump to later phases or adjacent modules unprovoked. The
  human sets the pace and is the driver; you are the pair-programming guide.
- **Pair the Hardcaml with its Verilog source.** When porting `Foo.v`, keep the original
  open, map signal-by-signal, and call out anywhere the Hardcaml idiom differs from the
  RTL transliteration (and why).
- **Verify each step.** No module is "done" until it passes its test against the oracle
  (see §6). Green tests are the unit of progress, not lines written.
- **It's fine to go slow and re-explain.** If a concept needs more grounding, give it.

---

## 1. What we're porting (the sources)

Everything lives under `test/_po/` (originals, git-ignored; the co-sim fetches the Verilog on
demand — §6) and the three sibling emulator repos.

### The Verilog — this is the spec
`test/_po/verilog/src/` (from `OStationVerilog.zip`, rev. 2015/2018 — fetched + checksum-pinned by
`test/rtl-sources.txt`):

| File | What it is | Notes |
|---|---|---|
| **`RISC5.v`** (184 L) | **The CPU core** — the crown jewel | single-issue, mostly 1-cycle, stall-based multi-cycle units + interrupts |
| `RISC5Top.OStation.v` | The SoC: MMIO map + peripheral wiring + Xilinx primitives | the `RISC5Top` module; our Phase 6/7 target |
| `Registers.v` | Triple-port register file | uses `RAM16X1D` (async read, sync write) — we re-infer this |
| `Multiplier.v` | Iterative signed/unsigned multiply | 33-cycle, state counter + `stall` |
| `Divider.v` | Iterative divide | 33-cycle, state counter + `stall` |
| `LeftShifter.v` / `RightShifter.v` | Combinational barrel shifters | staged 16/8/4/2/1; RShift does ASR+ROR |
| `FPAdder.v` (132 L) | Pipelined FP add/sub (also FLT, FLOOR) | 3-state pipeline |
| `FPMultiplier.v` / `FPDivider.v` | Iterative FP mul / div | 25- / 26-cycle |
| `PROM.v` | Boot ROM (512×32) | `$readmemh` of `prom.mem` |
| `RS232R.v` / `RS232T.v` | UART receive / transmit | |
| `SPI.v` | SPI master (SD card + net) | |
| `VID60.v` | Video controller (1024×768×1, DMA from RAM) | drives `stallX` on the core |
| `PS2.v` / `MousePM.v` | PS/2 keyboard / PS/2 mouse | |
| `RISC5.OStation.ucf` | Pin constraints (Spartan-3) | we rewrite as a Nexys 4 `.xdc` in Phase 7 |

Boot ROM image: `test/_po/verilog/prom.mem` (hex) + `test/_po/verilog/prom.bmm`.

### The docs
- `test/_po/RISC-Arch.pdf` (3 pp) — **ISA encoding** (the cheat sheet in §7 is distilled from this).
- `test/_po/RISC.pdf` (24 pp) — Wirth's detailed design writeup.
- `test/_po/PO.Computer.pdf` (21 pp) — the board/SoC overview.

### The reference emulators (oracles & cross-checks) — sibling repos
- `../oberon-risc-emu-ocaml/` — **OCaml emulator; our primary golden model.** Library
  `risc_core` (`lib/`), interface `lib/risc.mli` exposes the differential hooks we need:
  `cpu_state : t -> {pc; r; h; flags}`, `For_tests.single_step`, raw RAM/reg/MMIO access.
  Has a layered C co-sim harness (`test/cosim/`) and **frozen FP vectors**
  (`test/data/fp_vectors.txt`). Because Hardcaml *is* OCaml, this plugs in in-process.
- `../oberon-risc-emu/` — Peter De Wachter's **C reference** (`src/risc.c`, `risc-fp.c`).
- `../oberon-risc-emu-rs/` — Rust port; **`DIVERGENCES.md` is required reading** (see §8).

---

## 2. Locked decisions

1. **Fidelity — faithful where structure *is* the spec, idiomatic where it isn't.**
   A cycle-accurate port of `RISC5.v`, **not** a fresh behavioral model — but "the Verilog is
   the spec" means its *behavior*, not its syntax. **Mirror the sequential skeleton exactly:**
   which signals are registered, stall/state-counter timing, MUL/DIV's 33 cycles, interrupt
   timing — that's what synthesis *preserves* (it takes register placement as given), not
   optimizes, and what the Phase-8 formal-equivalence proof pins to `RISC5.v`. **Be idiomatic Hardcaml in the
   combinational datapath:** shifters, ALU ops, sign-extend, muxes — there only the truth
   table is observable and synthesis re-maps structure freely (`log_shift` LeftShifter ≡
   Wirth's radix-4 tree = the same point in the spec). Spend fidelity on *timing*, not on
   transliterating wires. *Caveat (learning build, §0):* idiomatic code can hide the hardware
   — still walk the structure for instructive blocks before shipping the idiom.

   *Semantics, not surface.* The Phases 0–8 mandate is cycle- and bit-exact *behaviour*, not
   surface-syntax/style matching to `RISC5.v` — so write **idiomatic, clean, readable**
   Hardcaml. Factor dense logic into named stages; bind sub-modules and stages to meaningful
   names and reach their outputs by dot-notation (a free *namespace* — `mul.stall` /
   `ex.result` reads better than a wall of destructured renames). Comment the **why** and the
   load-bearing design/mechanic, **not** a line-by-line footnote back to the RTL. The only
   surface we deliberately hold fixed is the timing skeleton (above) and the **register
   names** — the lockstep reaches `pc`/`ir`/the flags/`h` by name (`lookup_reg_by_name`), so
   those keep their RTL names; everything else is ours to make legible.

   *What cycle-fidelity is — and isn't — for.* The OCaml oracle is **instruction-level** (its
   ms-clock is injected via `set_time`, not cycle-derived; it steps by instruction), so it
   proves *behavioral* correctness and needs **no** cycle-accuracy — both the single-instruction lockstep and
   the boot checkpoint (§6) would pass a faster MUL just the same. Cycle-accuracy earns its keep on three *other* counts:
   the **exhaustive** Phase-8 equivalence proof vs `RISC5.v` (catching rare corners that
   sampling misses), `RISC5.v` as a **cycle-level debugging oracle** through the hard core/SoC
   phases, and the **bright-line discipline** (match the RTL exactly ⇒ no per-deviation "is this
   behavior-preserving?" judgment, nothing hiding in the oracle's blind spots). Trading these
   away for idiom or speed is deliberately deferred to Phase 9 (§5).
2. **Synthesizable** and aimed at a real bitstream (not sim-only).
3. **Board:** Digilent **Nexys 4 (XC7A100T)**, Vivado flow.
4. **Scope:** the **full SoC that boots** Project Oberon end-to-end.
5. **Memory:** build the **faithful shared single-port RAM + video-DMA stall** design first
   (free & exact in simulation); the **PSRAM async-SRAM adapter** (16↔32-bit width + stall-path
   wait-states) is a **deferred refactor** for board bring-up (see §4 — still needed since BRAM
   < 1 MB, but **far lighter than a DDR2/MIG** one).
6. **Oracle:** the OCaml `risc_core` emulator, in-process, plus its FP vectors + boot ROM.
7. **Toolchain:** **OxCaml** (opam switch `5.2.0+ox`) + Hardcaml **`v0.18~preview`** — chosen so
   the official `docs.hardcaml.org` matches our API exactly (it documents the OxCaml/preview
   build; vanilla opam stops at v0.17.1). Details and v0.18 API notes in §9.

---

## 3. Architecture: portable core + thin board shim

~90% of the design is **board-independent synthesizable RTL**; only a thin top-level shim
touches vendor primitives. Keep this separation strict. **Layout (§9):** the portable design
is `lib/` (library `risc5`); the Phase-7 board layer is `boards/<target>/` — its own library
(`nexys4_board`) depending on `risc5` one-way — and only that target's `nexys4_top.v`
instantiates vendor primitives.

**Board-independent (simulated *and* lockstep-verified):** RISC5 core, ALU, barrel
shifters, iterative MUL/DIV, the three FP units, the register file (as a normal 3R/1W
async-read array — let Vivado infer distributed RAM, don't instantiate `RAM16X1D`), and
all peripheral logic (RS232 R/T, SPI, PS/2, mouse, VID controller, MMIO decode).

**Board shim (the only Xilinx-specific layer, Phase 7):**
- **Clock:** original `DCM_SP ×5/÷12` (60→25 MHz) → Nexys `MMCM` 100→25 MHz. 25 MHz is a
  very relaxed target — timing closure is easy.
- **Main memory + video DMA:** the Cellular-RAM (PSRAM) async-SRAM adapter (see §4).
- **IO pads:** `IOBUF` for genuinely bidirectional pins (gpio, mouse `msclk`/`msdat`);
  `ODDR` only if a DDR output trick survives. `IOBUF` on the bidirectional 16-bit PSRAM data
  bus **stays**; the original `ODDR2` clock-forwarding likely goes (async PSRAM forwards no clock).
- **Pins:** VGA (drive 1-bit mono onto the 12-bit DAC), PS/2, microSD (SPI), UART → `.xdc`.

---

## 4. The Nexys 4 memory reality (important)

The board is an excellent match for the OberonStation — 12-bit VGA, PS/2 via USB-HID bridge,
microSD/SPI, USB-UART, 100 MHz — and **unlike its DDR sibling, its external memory matches too**:

- External memory is **16 MiB Cellular PSRAM** (Micron **M45W8MW16**, 128 Mbit pseudo-static
  DRAM) presenting an **asynchronous SRAM interface** (`CE#`/`OE#`/`WE#`/`UB#`/`LB#`, `ADDR`/`DATA`).
  In async mode the chip **auto-refreshes its own DRAM arrays**, so — in the manual's words —
  it needs only *"a simplified memory controller (similar to any SRAM controller)."* **No MIG, no
  refresh/burst/latency handling** — the thing that made the DDR rev hard is simply absent here.
- Two genuine-but-light mismatches remain: (1) the bus is **16-bit wide** while the core presents a
  **32-bit word** (our `sram.ml` models exactly that), so each word is **two halfword accesses**
  (`UB#`/`LB#` carry the byte-store lanes); (2) async cycle time is **~70 ns** ≈ 2 clocks at 25 MHz,
  so a word costs a **handful of clocks** of wait-state.
- Internal **BRAM is only ~607 KB** (4,860 Kbit) — **below** Oberon's standard **1 MB** map (the
  framebuffer sits at `0xE7F00–0xFFEFF`, the top ~98 KB). So the full faithful memory still can't
  live in BRAM on the `100T`; the external PSRAM holds it (16 MiB ≫ 1 MB — we map a 1 MB window).

**Consequence & why deferral is safe:** all verification happens in *simulation*, where a flat 1 MB
BRAM model makes the faithful shared-RAM design exact and free. On the bitstream the memory layer is
the one place that adapts — but the adapter is now a **small 16↔32-bit width FSM over an async-SRAM
controller** that **presents the same word interface and inserts its ~70 ns wait-states through
`RISC5.v`'s existing stall path** (the `stallL0/L1` load/store mechanism). The CPU core stays
byte-for-byte unchanged, so nothing in Phases 0–6 depends on how memory is backed — and the original
async-SRAM write path is **retained and adapted, not replaced** (the PSRAM *is* SRAM-like), keeping
us close to `RISC5Top`'s native design.

*(Synchronous 104 MHz burst mode exists if we ever want the bandwidth, at the cost of a clocked burst
controller; async is the simple default and ample at 25 MHz. And if zero memory refactor were ever a
priority, an Artix `200T`-class part has ~1.6 MB BRAM — enough to hold the whole 1 MB internally — but
the PSRAM adapter is light enough that we're keeping the Nexys 4.)*

---

## 5. Phased plan

Phases 0–6 are board-independent and fully verified in simulation; Phase 7 is the only
Vivado-specific layer.

| Phase | Deliverable | Oracle / proof |
|---|---|---|
| **0** ✅ | dune project on ox; emulator submodule + `oracle` wrapper lib; FP vectors & boot ROM via submodule; waveterm waveform rendered in the smoke | scaffold smoke (`dune test`) green |
| **1** ✅ | `LeftShifter`, `RightShifter`, ALU logic/adder + C/V flags | unit specs / qcheck |
| **2** ✅ | Register file (3R/1W async-read array) | unit |
| **3a** ✅ | `Multiplier`, `Divider` (state counter + stall) | qcheck vs pure-OCaml integer reference (signed/unsigned 64-bit `*`, floored `/`); hardware-accurate (see §8 unsigned-`MUL` note) |
| **3b** ✅ | `FPAdder`/`FPMultiplier`/`FPDivider` (+ FLT/FLOOR) | reachable-domain `fp_vectors.txt` + `Oracle.Fp` fuzz; RTL co-sim vs the `.v` (`test/cosim/`) |
| **4** ✅ | **CPU core** = PC/IR + control unit + stall aggregation + interrupts + N/Z (from `regmux`) | **single-instruction lockstep** vs `Oracle.Risc.For_tests.single_step`, fuzzed (steering around §8); the interrupt FSM has no oracle (the emulator is interrupt-free), so it's a behavioural waveform vs `RISC5.v` instead — exhaustively the Phase-8 co-sim |
| **5** ✅ | Memory + SoC harness + **SPI/SD-card master** (the one peripheral boot needs); boot the ROM through SD load to the **OS handoff** (`pc=0`) | **boot-handoff checkpoint** vs the oracle on the same `.dsk` (loaded image + arch state at the handoff) + SoC integration unit tests; plain Cyclesim interpreter, opt-in via `dune build @boot_checkpoint` (§6) |
| **6a** ✅ | **Remaining peripherals**, each a faithful port: UART (`RS232R`/`RS232T`), PS/2 keyboard (`PS2`), PS/2 mouse (`MousePM`), video controller (`VID`, framebuffer DMA) | per-module **co-located `ppx_expect`/`qcheck` + Verilator RTL co-sim** vs the `.v` (`test/cosim/`) — the proven Phase 1–5 stack. (`hardcaml_step_testbench` + `event_driven_sim` were revisited at the mouse and **rejected**: its device model is a single sequential task, so the coroutine gave no benefit while running ~5× slower.) Closed with the **cosim-harness dedup** — a shared `run_serial_cosim` across SPI/RS232x/PS2 (+ the rename to `cosim.h`). VID is two-clock (`By_input_clocks`, the DCM→pclk a Phase-7 input); the mouse splits its open-drain `inout` into `*_oe` outputs + resolved inputs |
| **6b** ✅ | **SoC top** — the full `RISC5Top` MMIO map (UART 2/3, mouse + kbd 6/7, GPIO 8/9, LEDs + switches 1) + the **video DMA / `stallX`** path; framebuffer out | **visual golden** — boot past the handoff to the idle Oberon desktop and assert the framebuffer is byte-identical to the oracle (hash `0xb9bdbf56ba51298d`, 18607 px; `dune build @visual_golden`). It surfaced a real **core** bug the single-instruction fuzzer structurally missed: ADD/SUB set the flags from `op` alone, lacking `RISC5.v`'s `~p`, so a *stalled* conditional branch whose op-field is 8/9 clobbered C → a spurious trap ~17.3 M cycles in. Caught + root-caused by a new **boot-stream RTL co-sim** (capture the core's per-cycle I/O over the boot, replay through `RISC5.v` under Verilator, find the first divergence — now the `core` unit of `dune build @cosim`, the core's first *cycle-level* RTL check before Phase 8). Fixed (one `~p`) + guarded in the fast suite (the ALU qcheck now drives `p`; the lockstep branch-gen now reaches op-field 8/9). The boot-handoff checkpoint extension over the new region stays a later option |
| **7** ✅ | **Board shim:** `MMCM`, `IOBUF`/`ODDR`, **Cellular-RAM (PSRAM) async-SRAM adapter**, VGA/PS2/SD pins, `.xdc` → **bitstream**. The Phase-6 design ports **nearly unchanged** onto a **Nexys 4** and **boots Project Oberon to the idle desktop from an SD image** on real silicon. One bug surfaced — **horizontal video flicker** — whose cause the **Phase-8 formal layer had already pinpointed**: VID's framebuffer-fetch **CDC**, the one spot not cycle-equivalent to `VID60.v`. The Phase-6 `caught`/`req` handshake sampled a `pclk` flop directly in `clk` with no synchroniser (+ a clk→pclk feedback) — deterministic in sim, metastable/timing-marginal on silicon. **Fixed** with a metastability-safe **toggle pulse-synchroniser** (`lib/vid.ml` `pulse_sync` — proven no-loss/no-spurious for all phases in Phase 8; the cosim + visual-golden confirm it's output-identical) **+ the matching `.xdc` CDC constraints** (`nexys4.xdc`: `set_clock_groups -asynchronous` clk25↔clk65 + `ASYNC_REG` on `sync0/1/2` — a `set_max_delay -datapath_only` on the `req_toggle→sync0` hop is deliberately *not* used: clock_groups outranks it in Vivado and would render it inert, and the routed hop is already ~0.95 ns; see the `nexys4.xdc` note). **Flicker confirmed gone on real hardware (both PO and EO)** — the fix holds on silicon. Post-route timing closes with WNS 9.389 ns (pixel domain) / 20.992 ns (clk25 domain), all constraints met. *Note:* the single onboard PS/2 port is wired to the mouse; the **PS/2 keyboard's on-hardware test is pending a Pmod PS/2 adapter** for the 2nd port (the `PS2` controller itself is proven in @formal + cosim, so this is a board-wiring bring-up step, not a design gap). | on-hardware boot ✅ |
| **8** *(stretch)* ✅ *(in-scope)* | `test/formal` / `@formal`, two modes: **combinational** (`hardcaml_of_verilog` import + `hardcaml_verify` `Sec` + z3) and **sequential** (emit our Verilog → yosys `equiv_induct`, k-induction). **Working**: both shifters (z3) + the Multiplier, Divider and all three FP units (FPAdder/FPMultiplier/FPDivider; yosys, FFs paired by name) proven ≡ their `.v`, plus the **register file** proven ≡ a behavioural spec (`registers_spec.v` — `Registers.v`'s duplicated bit-sliced `RAM16X1D` is a synthesis idiom with incongruent state, so we prove the 16×32/3R/1W *contract*; §2/§3). Every datapath unit proven. And the **whole core glue** — incl. the **in-situ ALU** (`aluRes`, no standalone `.v`) — proven ≡ `RISC5.v` with the 8 submodules black-boxed (assume-guarantee: `equiv_make` merges + checks the unit inputs, `cutpoint -blackbox` assumes their outputs, sound on the leaf proofs; teeth-checked by mutation). The datapath + core layer is closed, and the **Tier-1 peripherals are now proven too** — the same yosys `equiv_induct` path extended to the faithful-`.v` peripherals (the exhaustive upgrade of their Phase-6a cosim): **Tier 1** RS232R/T, SPI, PS2 ✓ (clean single-clock FSMs as `sequential` rows; each lib register *named*, then paired to the RTL by a per-row `renames` list — e.g. `q0→Q0`, `spi_shreg→shreg`; SPI's `rdy` `output reg` pairs via the output port; PS2's 16×8 `fifo` pairs through the `memory` pass like the register file), **plus the Mouse** (Tier 2) ✓ — its open-drain `inout msclk/msdat` (we split into `*_oe`+resolved-input) handled by two shims wrapping *both* sides into one explicit interface with a **free** external read (else yosys ties the inout read to 0 and the FSM degenerates — a vacuous proof) and the resolved line `oe ? 0 : ext` as the observable; the tristate lowered by `tribuf -formal`/`chformal -remove`/`setundef -one` (the pad pull-up). **And VID** (Tier 2) ✓ — a *partial* multiclock proof: drop `VID60.v`'s DCM (Phase-7 primitive) + `expose -input pclk`, **cut** `vidbuf` to a shared free input so the raster + pixel datapath prove ≡ `VID60.v` *given the fetched word*, and **`equiv_remove`** the `req` handshake — the framebuffer-fetch CDC deliberately departs (our toggle pulse-synchroniser vs the RTL async-set `req1`). That departure's **fetch invariant** is then closed by a *property* proof (`vid_invariant`): the extracted `pulse_sync` primitive is proven **one-`req`-per-`req0`, no loss, no spurious — for all clk/pclk phases and all reachable states** via `yosys-smtbmc -i`/z3 **k-induction** (the engine SymbiYosys wraps; no `sby` needed — and no hand-crafted inductive invariant: k≈48 spanning a fetch cycle suffices) — the CDC-robustness the single-phase Cyclesim test can't reach. The 2-group prefetch's `vidadr` departure is closed the same way — by **decomposition**: its look-ahead address is proven ≡ an independent geometry spec (`vid_addr`, combinational `Sec`/z3, all `(hcnt,vcnt)`), timing comes from `vid_invariant`, and a **reviewed composition lemma** glues them (the one place a hand argument bridges the mechanized pieces; the monolithic all-phases proof doesn't converge — col 0 is cross-line; see test/formal/README "VID prefetch"). **17 checks** total, each mutation-checked. *(That VID-CDC departure was no longer just a sim artifact: its `caught` one-shot turned out to be a real metastability bug on the Nexys 4 — horizontal flicker — so `vid.ml` now ships the synchroniser the proof is built around; the formal layer flagged the exact fragile spot.)* **Out of scope:** the SoC top (`RISC5Top`) — board-specific, our sim `Soc` ≠ `RISC5Top.OStation.v` by design (DCM/PROM/IOBUF/memory are Phase 7); revisit only if a board SoC lands. See test/formal/README | z3 `Unsat` / yosys all-`$equiv`-proven |
| **9** *(stretch)* ✅ *(compute arc)* | **Optimization pass** — from the verified-correct, Phase-8-proven baseline, make it faster / more idiomatic: DSP-backed `*:`/`*+` for MUL/DIV, pipelining, idiomatic rewrites, dropping iterative stalls where behavior-preserving. *Landed:* DSP MUL + FML, pipelined to **60 MHz**, benchmarked end-to-end (`test/bench/`). *Deferred:* Newton-Raphson DIV. *Verdict:* memory-bound, not compute-bound → Phase 10 | architectural lockstep only (instruction-level state + Oberon still boots & runs end-to-end); cycle-accuracy & formal eq vs `RISC5.v` intentionally relaxed |
| **10a** *(stretch)* ✅ *(memory arc)* | **I-cache** — the Phase-9 verdict acted on. A direct-mapped, write-through read/I-cache (`Icache`) in front of `Cellram`, in the **board layer** so the core stays byte-identical (§8): async-read LUTRAM (the register-file idiom) gives a **0-stall combinational hit** (drop `mem_pend`, so Cellram's `ce = ~mem_pend | …` rises the same cycle); write-through + **snoop-invalidate** = transparent coherence (Oberon has no flush op — the real machine has no cache). *Landed:* **~6× on running-OS code** (93% hit-rate), boots clean on **real hardware**, 60 MHz still closes (the cache fill path is now the critical path); 720 LUT distributed RAM, **0 BRAM**. *Deferred:* burst/wide-PSRAM fill, D-cache (10b/c) | architectural lockstep + **coherence**: byte-identical desktop with the cache ON (`@visual_golden_board`) + 28.8K-instr pc-lockstep vs cache-off; `Icache`'s own co-located fill/hit/snoop tests |

*Correct before fast (Phase 9).* Phases 0–8 hold the cycle-accurate mandate (§2), which keeps
`RISC5.v` a *total* oracle — a bright line that keeps the spec unambiguous and bugs findable. Phase 9
is the one place we deliberately cross it, only *after* the faithful port is verified (and formally
checked in 8): optimizations there are judged against the **ISA/oracle** — does Oberon still boot and
lockstep at the instruction level — not against `RISC5.v` timing. Work from a tagged faithful baseline
(e.g. a `feat/fast-mul` spike), so the proven port is never lost.

*Phase 9 — landed: DSP multiplier (`?fast_mul`).* The iterative 33-cycle `Multiplier` is swappable
for a **combinational DSP-backed** `Multiplier.create_opt` — the same 32×32→64 multiply as one signed
33×33 `*+` (the §8 sign handling preserved: `y` always signed, `x` signed iff `u`), which Vivado lowers
onto **4 DSP48E1** slices. It rides the existing `Risc5_core.Units` seam, selected by `?fast_mul`
(default `false`) threaded `Risc5_core.create` → `Soc_board.create`/`Soc.create` →
`emit_board_verilog` (only the board emit opts in). Proven **bit-identical** to the faithful `create`
by a co-located **differential qcheck** (20k cases, full 64-bit `z`) that rides `create`'s Phase-8
proof transitively — *not* re-formalised. Per-MUL cost 34→2 core cycles (`@bench`). Validated top to
bottom: synth infers the 4 DSP48E1 and **50 MHz closes** (WNS +1.521 ns — the combinational MUL is now
the critical path, `regfile → 2×DSP48E1 cascade → result`; a DSP48E1 `MREG`/`PREG` pipeline stage is
the free fix if the clock ever passes ~54 MHz); the board boot checkpoint + visual golden pass *with*
`fast_mul`; and on **real hardware** it boots Oberon to the desktop and **rebuilds the entire Extended
Oberon system with no traps**. The default core stays byte-identical — all Phase 0–8 gates
(`runtest`/`@cosim`/`@formal`/`@boot_checkpoint{,_board}`/`@visual_golden`) green with the seam inert
at `fast_mul=false`.

The same `?fast_mul` flag now also swaps the **FP multiplier**: `Fp_multiplier.create_opt` expresses
`FPMultiplier.v`'s 24-iteration mantissa loop as one unsigned 24×24 `*:` (→ DSP48), reusing the
exponent/round wrapper (factored into a shared `pack`) verbatim — so bit-exactness again reduces to
"same `P`", proven by its own differential qcheck (20k cases) against the formally-proven iterative
unit. `@formal` still closes `create ≡ FPMultiplier.v` after the `pack` refactor. Synth now infers
**6 DSP48E1** (4 integer + 2 FP) and 50 MHz still closes (WNS +0.897 ns — the FP multiply, being
`regfile → 2×DSP48E1 → round → reg`, is now the tightest path); boots Oberon clean to desktop on
hardware. **Remaining:** DIV and `FPDivider` stay iterative — division has no DSP primitive, so the
real win is Newton-Raphson (reciprocal refinement *using* these DSP multipliers), a genuine algorithm
change with delicate bit-exactness — a deferred project, not low-hanging like the two multiplies.

*Phase 9 — landed: 60 MHz build.* Pipelining closed what the combinational muls left open —
`Multiplier.create_opt_pipelined` / `Fp_multiplier.create_opt_pipelined` add `?stages` registers on the
DSP product that Vivado retimes into the DSP48 `MREG`/`PREG`, moving the multiply *off* the critical
path and letting the system clock reach **60 MHz** (`mul_stages:2`; MMCM VCO 780, WNS +0.9 ns; the new
limiter is the FPAdder normalize/round). The pipelined core is lockstep-checked (a `~fast_mul
~mul_stages:2` run of `test_cpu_lockstep` — the units are already differential-qcheck'd, so this pins
the 2-cycle-stall integration under the real core's driving). A companion UART-baud parameterization
(`RS232R/T ?baud_slow/?baud_fast`) keeps the wire at a standard rate off the 60 MHz clock (115200
default, ~5× serial-read throughput); the faithful 25 MHz constants would give 46083 baud. Boots clean
on hardware.

*Phase 9 — the verdict (benchmarked, `test/bench/`).* Three gauges compose the end-to-end picture: MUL
is **34→2 cycles (17×)** per op (`@bench`), but only **0.1% of executed instructions** (`@profile_boot`)
— an Amdahl ceiling of ~3.3%, so **+0.00% end-to-end on a boot** (`@bench_boot`, faithful vs `fast_mul`
identical to the cycle). Meanwhile **~24% of boot cycles are PSRAM wait**, and that *understates* the
running OS: boot fetches code from the on-chip ROM fast-path, but the OS fetches every instruction from
PSRAM. The broad win actually banked is the **50→60 MHz clock, 1.2×**, on compute and memory alike.
**The compute-optimization arc of Phase 9 is done** — the DSP multipliers were right to build (free once
the DSP48s are placed, and they *enabled* the clock bump), but further multiply/clock work is Amdahl- or
memory-capped. The next lever is memory, not compute (Phase 10). See `test/bench/README.md`.

### Phase 10a ✅ + 10b/c *(potential)*: memory — a cache

The Phase-9 benchmark pointed here unambiguously — the machine is **memory-bound**: every OS instruction
fetch is a multi-cycle PSRAM read (`read_cycles:5` at 60 MHz), so the leverage is cutting memory latency,
not adding compute. **Phase 10a landed the instruction cache and confirmed the diagnosis on silicon.**

**10a — the I-cache (done).** A small direct-mapped, write-through read/I-cache
(`boards/nexys-4/icache.ml`, default 1024 one-word lines = 4 KB) in front of `Cellram`, in the **board
layer** — never `lib/`, so the core stays byte-identical and its Phase-8 proof is untouched (the latency
it fights is a board phenomenon; the `lib/` sim has single-cycle memory). Two design choices carry it:

- **0-stall combinational hit.** The tag/data array is **async-read distributed RAM** (`multiport_memory`,
  exactly the register-file idiom §2/§6 — BRAM can't read combinationally). On a hit, `soc_board` drops
  `mem_pend` to `Cellram`, whose `ce = ~mem_pend | …`, so `ce` rises the *same* cycle and the word is
  muxed from the cache: a hit costs zero stall cycles, no new pipe stage, no core change. Synthesises to
  `RAMS64E` LUTRAM (720 LUT distributed, **0 BRAM**); 60 MHz still closes with the *fill* path (`pc_reg →
  icache_mem write` ≈ 15.6 ns) as the new critical path — the register file's async-read twin.
- **Coherence with no flush op** (Oberon has none — the real machine has no cache). One invariant: *a
  valid line always equals PSRAM*, because fills copy PSRAM and the cache issues no writes itself
  (Cellram's write path is unchanged = write-through). The only staleness risk is a write to a cached
  address, which we **snoop**: a CPU store invalidates a matching line. Three cases — **CPU→CPU** (incl.
  the module loader writing code then jumping into it — the case that would otherwise trap the OS),
  **CPU→video** (write-through keeps the framebuffer live for the video DMA's own, never-cached read
  port), **video→CPU** (read-only, nothing to snoop). Because the invariant holds *continuously*, no
  reset-invalidate is needed: the LUTRAM powers up `INIT=0` (all lines invalid) at configuration.

Result: **~6× on running-OS code** (93% hit-rate), +5% through boot (already ROM-fast-pathed), and the
board "boots clean, runs way smoother" on real hardware. Verified by the usual layers, now cache-aware:
`@bench_boot` (a *same-work* instruction-lockstep off-vs-on compare — the honest number, not
phase-drifted throughput), `@visual_golden_board` (**byte-identical** idle desktop with the cache ON = a
full coherence proof, the Phase-6b golden re-run through the board SoC), the 28.8K-instruction pc-lockstep
it rides on, and `Icache`'s own co-located fill/hit/snoop-invalidate tests (§6).

**10b/c — further, deferred.** *Burst / wider PSRAM fill* — the bus is 16-bit (two half-words per word); a
32-bit or burst path (the M45W8MW16's synchronous burst mode) lowers the miss penalty and helps *all*
traffic, and is where multi-word cache lines pay off (the cache becomes its fill engine). *D-cache / write
buffer* — lower priority; loads/stores are a smaller slice than fetches. Verification stays
Phase-10a-style — judged against the **ISA/oracle**, not `RISC5.v` timing (a cache is a new architectural
block, not in the faithful RTL).

---

## 6. Verification strategy (the pyramid)

Each layer's oracle already exists next door — this is our biggest leverage.

**Two oracles, split by the question they answer.** The OCaml `risc_core` emulator is the
*system-state* oracle: bit-exact architectural state (`pc`/`r[]`/`H`/`flags`) at *instruction*
granularity (its ms-clock is injected, not cycle-derived — it sees no wire and no cycle). Its
home is single-instruction lockstep (layer 4) and the boot-handoff checkpoint (layer 5). The **original Verilog itself**, run
through **Verilator** (our `test/cosim/`), is the *wire-state* oracle: any signal at *cycle*
granularity, against the spec directly — the §2 fidelity authority (layer 3, exhaustively at
layer 6). They answer orthogonal questions — *is the result correct?* vs *did we copy the
spec?* — and cross-check: **every §8 divergence is the emulator differing from `RISC5.v`, and
the co-sim is what proves our port sides with the RTL.** (There is no Verilog→Hardcaml *source*
translator; `hardcaml_of_verilog` imports the `.v` as an in-process circuit — installable on the
preview via a forked `jsonaf` pin (§9) — but this periodic fidelity check still runs the `.v`
out-of-process under Verilator and compares dumps, which needs no yosys.)

1. **Unit specs** — exhaustive or `qcheck` for combinational blocks (shifters, ALU).
2. **FP vectors** — replay `fp_vectors.txt` through the FP units over the *compiler-reachable*
   domain (FLT/FLOOR always carry the fixed 2nd operand `0x4B000000`; steer around the
   unreachable forms where the C-derived oracle diverges from `RISC5.v` — see §8), plus a fuzz
   of the reachable conversion domain against `Oracle.Fp`.
3. **RTL co-sim (fidelity)** — our `test/cosim/`: dump the Hardcaml unit's outputs over a
   stimulus set, replay them through the reference `.v` under Verilator, assert bit-exact.
   Opt-in (needs Verilator; outside `dune runtest`). The reference `.v` is not vendored — the
   harness fetches it on demand into `test/_po/`, checksum-pinned (`test/rtl-sources.txt`). The
   OCaml dumper builds under `@check` so it can't rot. The simulation preview of layer 6: one
   shared `fp_dump.ml` over the FP units + a per-unit `<unit>.cpp`.
4. **Single-instruction lockstep** — drive random instructions into the Hardcaml CPU sim,
   compare architectural state (`pc`, `r[]`, `h`, `flags`) against `Oracle.Risc.For_tests.single_step`.
   `qcheck`-fuzzed, like the OCaml repo's `test/cosim/test_cosim_cpu.ml` (steering §8).
5. **Boot-handoff checkpoint** — *not* per-instruction lockstep, which a booting machine defeats
   (the §8 code-address skew while running from ROM, the interrupt-free oracle, its injected vs our
   cycle-derived ms-clock, and SD/timer poll timing all diverge step-by-step without diverging in
   *result*). Instead: drive our SoC's SD card from the **same `Oracle.Disk` + `.dsk`** the oracle
   boots, run both through the SD load to the **OS handoff** (the boot loader jumps to the inner
   core at `pc=0` in low RAM — empirically ~403 K instructions, ~21 K SPI transactions), and compare
   the **loaded image + architectural state there**. Exact because the handoff is where
   representations realign: low-RAM code is bit-identical (§8 self-heals), the bootstrap is
   interrupt-free, and only the end result — not per-step timing — is compared. Plain Cyclesim
   interpreter (~0.39 M cycles/s, `trace_all`/`lookup_*` free; `hardcaml_c` rejected at ~3.5× with
   multi-min `eval.c` compiles, `hardcaml_verilator` won't build vs Verilator 5.048 — §9). **Opt-in** — the ~22 s boot is too slow for the default
   `dune runtest` (like the RTL co-sim), so run it with `dune build @boot_checkpoint`. The full
   boot past the handoff + framebuffer is the Phase-6 visual golden.
6. **Formal** — *prove* (not sample) our port equivalent to the reference `.v`; the exhaustive form
   of layer 3, in `test/formal` (`@formal`, opt-in like the co-sim). Two modes, because combinational
   and sequential equivalence want different tools. **Combinational**: `hardcaml_of_verilog` imports
   the `.v` to a `Hardcaml.Circuit.t` (yosys) and `hardcaml_verify`'s `Sec` SAT-checks it against ours
   (z3) — needs only matching *port* names; both shifters proven ≡ `LeftShifter.v` / `RightShifter.v`.
   **Sequential**: `Sec` pairs registers by name and the import mangles/regroups them, so instead we
   *emit* our Verilog (`Rtl`) and prove equivalence inside yosys (`equiv_make` pairs flip-flops by
   name → `equiv_induct`, *unbounded* temporal induction — all states, not a bounded trace); needs
   only yosys, but the *register* names must match the RTL too (the Multiplier names its `S`/`P`).
   Multiplier, Divider and all three FP units proven ≡ their `.v`. The **register file** is the one
   unit proven against a *behavioural spec* (`test/formal/proofs/registers_spec.v`: 16×32, 3 async reads, 1
   sync write) instead of Wirth's `Registers.v` — whose 64 duplicated, bit-sliced `RAM16X1D`
   primitives are a synthesis idiom whose state (1024 bits, vs our array's 512) is structurally
   incongruent: nothing for `equiv_make` to pair, and a memory miter isn't inductive on outputs alone
   (only a shallow *bounded* check is tractable). Both sides are one array, so the sequential script's
   `memory` pass lowers them to flip-flops that pair by name and `equiv_induct` closes; that `RAM16X1D`
   meets the same contract is Vivado's distributed-RAM inference, not ours (§2/§3 — the regfile is the
   canonical "structure is not the spec"). Every datapath unit now proven. The ALU has **no** standalone
   `.v` (`aluRes` inline in `RISC5.v`; our `Alu` is a refactored grouping — folds `C0`→`c1`, zeroes
   the other units' op slots — not an RTL slice), so it is proven **in situ**: the whole core glue
   (decode, the inline ALU, control, flags, the 13 state registers) is checked ≡ `RISC5.v` with the 8
   submodules black-boxed and *assumed*-equivalent on the leaf proofs above. `Risc5_core.create_with_units`
   is the seam — `Core_blackbox` feeds it `Instantiation` stubs (names matched to the RTL), and
   `proofs/core.ys.template` (via `Yosys_equiv.run_proof`) runs the assume-guarantee flow: `equiv_make` merges the matched unit cells
   (checking their *inputs* via the `$equiv` on the named nets), `cutpoint -blackbox` cuts the merged
   units' *outputs* to shared free signals, and `equiv_simple`/`equiv_induct` close the glue. Sound
   because no combinational path crosses a submodule boundary (so the core decomposes into glue +
   proven leaves); teeth-checked — mutating a glue constant leaves exactly the affected `$equiv`
   unproven. *(Harness: every yosys proof — the sequential units, the core, and the Tier-2 one-offs
   below — is one `Yosys_equiv.run_proof` driver filling a checked-in `.ys.template` under
   `test/formal/proofs/`; the proofs differ only in their template + a few subst values.)*

   **Peripherals (Tier 1/2).** The same path extends to the faithful-`.v` peripherals: RS232R/T,
   SPI, PS2 ≡ their `.v` (sequential `equiv_induct`, lib registers renamed to the RTL's); the
   **Mouse** ≡ `MousePM.v` through an open-drain `inout`→split-port shim (`tribuf -formal` + a
   free external-read wrapper); and **VID** ≡ `VID60.v` on its raster + pixel datapath (multiclock
   `equiv_induct`, `vidbuf` cut around the *deliberate* fetch-CDC departure), with that CDC's
   protocol — one `req` per `req0`, no loss, no spurious, all clk/pclk phases — proven **unbounded**
   by `yosys-smtbmc -i` k-induction (`vid_invariant`; the BMC/induction engine SymbiYosys wraps, no
   `sby` needed). 17 `@formal` checks, every one mutation-checked; full detail in `test/formal/README`.

**Harness — co-locate genuine unit/module tests; keep a separate harness only for
system-level tests.** Co-location is the default — reach for `test/` only when a test *can't* sit
in `lib`: it couples to the emulator oracle (the dep we deliberately keep out of `lib`), or it's a
system-level harness (the boot checkpoint). Module tests live *inline in the design
module's own `.ml`* via
`ppx_expect` (`let%expect_test`): waveform expect tests — render with `hardcaml_waveterm`,
freeze the ASCII waveform in an `[%expect]` block (`dune promote` updates it) — plus `qcheck`
property checks against a reference (for combinational blocks the reference is plain OCaml,
e.g. `x lsl sc`, so no oracle needed). Waveforms are especially valuable for the multi-cycle
units (MUL/DIV/FP stalls, CPU control), where the cycle-by-cycle timing *is* the test.
**Keep the frozen block tight:** set `~wave_width:4` — a bus cell is ≈ `2·w+1` wide, so 4 is the
floor that still renders a full 32-bit hex value (`3` truncates it) — and *pin* `~display_width`
to the rendered width rather than omitting it, so a rolling `v0.18~preview` default bump (§9) can't
silently reflow the frozen ASCII out from under the `[%expect]`. Find the pin once: render wide,
then shrink until the last cell keeps ~2 trailing spaces with no cycle clipped (≈70 for 5 cycles of
32-bit hex, ≈58 for 4; `left_shifter.ml` is the reference shape). Compose
with the oracle where it applies (single-instruction lockstep, Phase 4): waveform for visible
behavior + architectural-state assertions against `Oracle.Risc`.

Mechanics, with an honest caveat (verified empirically, not assumed — dune 3.22, ppx_expect
v0.18~preview). A co-located `let%expect_test` compiles *as part of the library*, so the tooling
it names (`hardcaml_waveterm`, `qcheck-core`) must sit in `lib`'s own `(libraries)`. Two corners we
checked rather than guessed: `(inline_tests (libraries …))` does *not* cover it — that only feeds
the generated test runner's link, not the library's own compile scope, so the build still fails
`Unbound module QCheck`; and the deps are needed in *every* profile — dune keeps inline-test bodies
under `release` as well as `dev` (md5-identical preprocessed AST), so there is no "non-test build"
that silently drops them. It's still fine, but the reason is *not* that builds shed the deps — it's
that they're host-side OCaml dev tools from the Jane Street/Hardcaml ecosystem we already use, and
they *never reach the generated Verilog*: `Rtl.print` lowers the circuit graph, not the library's
OCaml deps, so the netlist is identical with or without them. (Escape hatch, unused: `(pps …
-inline-test-drop)` strips the test bodies and their deps — at the cost of those tests in that
build.) The one dep we deliberately keep *out* of `lib` is the emulator — oracle-coupled tests
(single-instruction lockstep Phase 4, the boot checkpoint Phase 5) live in `test/` (depending on `risc5` +
`oracle`), so the synthesizable design never depends on the software model. `lib/dune` carries
`(inline_tests)` + `(preprocess (pps ppx_hardcaml ppx_expect))`.

---

## 7. ISA cheat sheet (distilled from `RISC-Arch.pdf` + `RISC5.v`)

Instruction fields (from `RISC5.v`): `p=IR[31] q=IR[30] u=IR[29] v=IR[28]`,
`a=IR[27:24] b=IR[23:20] op=IR[19:16] c=IR[3:0]`, `imm=IR[15:0] off=IR[19:0] disp=IR[21:0]`,
`cc=IR[26:24]`.

**Register instructions** (`p=0`; `q=0` → 2nd operand is `R.c` (F0); `q=1` → immediate `imm`
extended with 16 `v`-bits (F1)). Result → `R.a`; set N,Z; ADD/SUB also set C,V.

```
0 MOV   1 LSL   2 ASR   3 ROR   4 AND   5 ANN   6 IOR   7 XOR
8 ADD   9 SUB  10 MUL  11 DIV  12 FAD  13 FSB  14 FML  15 FDV
```
Modifier `u` specials: `ADD'/SUB'` add/sub carry C; `MUL'` unsigned; `MOV' q=0,v=0` → `R.a:=H`;
`MOV' q=0,v=1` → `R.a:=[N,Z,C,V]` flags word; `MOV' q=1` → `imm<<16`. `H` = MUL high word / DIV remainder.

**Memory** (`p=1,q=0`): `u=0` LD `R.a:=Mem[R.b+off]`, `u=1` ST. `v=0` word, `v=1` byte. `off` 20-bit signed.

**Branch** (`p=1,q=1`): target = `R.c` (`u=0`) or `PC+1+disp` (`u=1`); `v=1` links `PC+1`→`R15`.
Condition `cc` (negated when `IR[27]=1`): `0 MI(N) 1 EQ(Z) 2 CS(C) 3 VS(V) 4 LS(C|Z) 5 LT(N≠V) 6 LE((N≠V)|Z) 7 T`.
`RTI` = `1100 0111 … 0001 Rn`; `STI/CLI` = `1100 1111 … 0010 000e` (`intenb:=e`).

Reset (`rst` active-**low**) jumps to `StartAdr = 0x3FF800` (word addr); ROM decoded at
`adr[23:14]==0x3FF`.

---

## 8. Known divergences & gotchas

*These are all emulator-vs-`RISC5.v` divergences — the port follows the hardware (§2), and the
RTL co-sim (§6, `test/cosim/`) proves it. For OCaml lockstep the fuzzer steers around them;
against the RTL itself they can't arise.*

- **The flags/ID byte (resolved — not a steer-around).** `MOV'` flags-read returns
  `{N,Z,C,OV} | 0x53` — our `RISC5.v:113` emits low byte **`0x53`** (`{N,Z,C,OV,20'b0,8'h53}`).
  Our **OCaml oracle and the Rust port now both follow the hardware** and emit `0x53` (OCaml
  `risc.ml:335`, Rust `risc.rs:542`, guard test `mov_flags_read_is_hardware_0x53`). **Only the
  C reference still emits `0xD0`**, and C isn't our oracle — so the OCaml lockstep oracles this
  byte *directly*, no steering needed. Principle to keep regardless: **our Verilog is the spec.**
  See `../oberon-risc-emu-rs/DIVERGENCES.md`.
- **`ADD'/SUB'` carry with carry-in (the one remaining lockstep steer-around).** `RISC5.v`'s
  adder computes C/V from the real sign bits (lines ~161–166); the OCaml oracle derives C by
  comparison (`risc.ml:353`, `s < b`) and misses one corner (2nd operand `0xFFFFFFFF` with
  carry-in). We follow the hardware, so our port and the oracle differ *only* here — the fuzzer
  must steer around this case. (Unreachable from Oberon-07 compiled code anyway.)
- **Unsigned `MUL'` high word (a Phase-4 lockstep steer-around).** `Multiplier.v` sign-extends
  its *second* operand unconditionally (`{w0[31], w0}`, line 16); the module's `u` flag (driven
  `~u`, so `u=1`≡signed) controls *only* the MSB subtract, which flips the *first* operand's
  sign. So unsigned `MUL'` computes `B_unsigned × C1_signed`, whereas both emulators compute
  `B_unsigned × C1_unsigned` (OCaml `risc.ml:371`, C `risc.c:279`). The low 32 bits (the `R.a`
  result) always agree; only `H` differs, and only when `C1[31]=1`. We follow the hardware (§2),
  so the fuzzer must steer around `C1[31]=1` in unsigned-`MUL` lockstep. (Reachable only via an
  `H`-read after `MUL'`.)
- **FP FLT/FLOOR denormalize sign-fill (a co-sim non-issue; an FP-vector steer-around).**
  `FPAdder.v` fills its denormalize right-shift with the operand *sign bit*, while the C/OCaml
  model arithmetic-shifts the two's-complement *value* — they differ only for a
  negative-zero-mantissa operand being *shifted*, which surfaces only in FLT/FLOOR (FAD keeps
  its hidden bit, so it's immune; null-operand checks mask the rest). Unreachable in compiled
  code: the compiler (`ORG.Mod` `Float`/`Floor`) fixes the FLT/FLOOR 2nd operand to `0x4B000000`
  (2^23; exponent 150, positive), so no divergent shift occurs. Our port follows the hardware
  and is verified bit-exact to `FPAdder.v` over 26k stimuli (`test/cosim/`); the FP-vector
  replay (§6) steers around the non-`0x4B000000` forms.
- **Addressing.** FPGA uses a 20-bit RAM window (out-of-range aliases into 1 MB) + a 22-bit word
  PC; emulators decode 32 bits. Identical for well-behaved software. The divergence is confined to
  *code addresses*: the oracle's ROM base (byte `0xFFFFF800`, pc word `0x3FFFFE00`) differs from
  ours (`RISC5.v`'s `StartAdr` word `0x3FF800`), so `pc` and `R15` links differ by a constant
  offset *while running from ROM* — not a low-bit mask (the ROMs sit at different offsets-from-top).
  Data addresses and **all low-RAM code are bit-identical**, so it self-heals the moment the OS runs
  from low RAM — which is why boot is verified by a handoff checkpoint, not per-instruction lockstep
  (§6 layer 5).
- **Register file timing:** **async read** (combinational `dout` from the read address),
  **sync write** on `clk`. Three read ports; `rno0` is *also* the write address. `ira0 = BR
  ? 15 : ira` (branch links to R15).
- **Stalls freeze PC & IR.** Multi-cycle units assert `stall` until their state counter hits
  terminal (MUL/DIV `S==33`, FPAdd `State==3`, FPMul `S==25`, FPDiv `S==26`). LD/ST take an
  extra cycle (`stallL0/L1`). `stallX` is the external video-DMA stall.
- **Interrupts:** `intAck = intPnd & intEnb & ~intMd & ~stall`; vector is address `1`; `SPC`
  saves `{flags, pcmux0}`; `RTI` restores. `STI/CLI` sets `intenb`.
- **`C1`** (2nd ALU operand) `= q ? sign/zero-extended imm : R.c`. Byte access uses `ben` to
  select/replicate the active byte lane on `inbus1`/`outbus`.

---

## 9. Repo layout & toolchain

```
oberon-risc-hardcaml/
  AGENT.md / CLAUDE.md    ← this file (CLAUDE.md is a symlink to AGENT.md)
  dune-project, dune      ← root build config (dune restricted to: lib boards test vendor)
  lib/                    ← Hardcaml design library `risc5` (placeholder in Phase 0;
                            real modules — shifters, ALU, CPU core… — from Phase 1)
  boards/                 ← board-specific layer (Phase 7); one dir per target. The
                            git-ignored generated/build trees are hoisted out (below) so
                            each boards/<target>/ stays 100% tracked source.
    nexys-4/              ← Nexys 4 target = library `nexys4_board` (depends on `risc5`,
                            never the reverse → lib/ stays board-independent):
      cellram.{ml,mli}        PSRAM controller + CPU/video arbiter (synthesizable, vendor-free)
      cellram_model.{ml,mli}  sim double of the external PSRAM chip (test-only; never synthesized)
      icache.{ml,mli}         Phase-10a direct-mapped write-through I-cache (async LUTRAM) — 0-stall hit before Cellram
      soc_board.{ml,mli}      board SoC — core(`ce`) + Cellram + peripherals + video (+ optional Icache)
      nexys4_top.v          hand-written shim: MMCM / IOBUF / POR — the ONLY vendor code
      nexys4.xdc            pin constraints (derived from the Digilent master XDC)
      *.tcl, gen_verilog.sh Vivado emit → synth → program flow
      README.md             Phase-7 design log + resume notes
    _generated/<target>/  ← git-ignored: soc_board.v emitted from Hardcaml
    _build/<target>/      ← git-ignored: Vivado runs + the bitstream
  test/                   ← tests; `test_fp_*` + `test_cpu_lockstep` = the fast suite,
                            `test_boot_checkpoint` = Phase-5 boot checkpoint
                            (opt-in: `dune build @boot_checkpoint`), cosim/ = RTL co-sim,
                            formal/ = logic-equivalence proofs (`@formal`, Phase 8)
    fetch-rtl.sh          ← fetch + checksum-verify the reference .v on demand (shared by
    rtl-sources.txt         cosim + formal); the provenance pins live in rtl-sources.txt
    _po/                  ← original sources, git-ignored; fetch-rtl.sh populates
                            verilog/src/*.v on demand. prom.mem + *.pdf placed locally
    _work/                ← test scratch, git-ignored (Verilator obj_dirs, dumped traces,
                            the downloaded zip, yosys/z3 intermediates); safe to delete
  vendor/
    oberon-risc-emu-ocaml/  ← git submodule: the OCaml emulator/oracle, pinned
                              (data_only_dirs: dune ignores its own project files)
    oracle/               ← compiles the submodule's lib/ into library `oracle`
                            (Oracle.Risc, Oracle.Fp, Oracle.Boot_rom, …)
```

**Board layer layout (Phase 7, locked).** Each target is `boards/<target>/` — a
vendor-primitive-free Hardcaml library (`nexys4_board`: the synthesizable board design
`cellram`/`icache`/`soc_board`, plus `cellram_model`, the sim chip-double) that depends on `risc5`
*one-way*, so the compiler (not convention) keeps `lib/` board-independent (§3). The lone
vendor primitives (MMCM/IOBUF/POR) live in the hand-written `nexys4_top.v`. Generated/build
artifacts hoist to `boards/_generated/<target>/` + `boards/_build/<target>/` — two all-boards
`.gitignore` entries (`/boards/_generated/`, `/boards/_build/`) — so every `boards/<target>/`
stays pure tracked source. Tests follow §6: `cellram`'s unit checks co-locate inline against
`cellram_model` (both in the board lib, no oracle); only the oracle-coupled board boot
checkpoint + the faithful SD model live in `test/`.

**Oracle wiring (decided Phase 0).** `oberon-risc-emu-ocaml` is a git submodule under
`vendor/`. Its `risc_core` is a *private* library behind its own `dune-project`, which dune
won't expose across the project boundary — so `vendor/oracle/dune` `copy_files` its `lib/`
sources and builds them as library **`oracle`** in our project (warnings off; only dep is
`unix`). Self-contained and leaves the submodule pristine. *Cleaner alternative if ever
wanted:* give the emulator a `public_name` upstream (needs a package stanza in that repo),
then depend on it directly and delete the wrapper. FP vectors
(`vendor/oberon-risc-emu-ocaml/test/data/fp_vectors.txt`) and the boot ROM
(`Oracle.Boot_rom`) come straight from the submodule — no copies needed.

**Toolchain:** **OxCaml** — opam switch **`5.2.0+ox`** (`ocaml-variants.5.2.0+ox`), dune
`3.22+ox`, Hardcaml **`v0.18~preview`** (with `ppx_hardcaml` + `hardcaml_waveterm`, same
version). We track Jane Street's OxCaml *preview channel* on purpose: **`docs.hardcaml.org`
documents exactly this version** (built from the `with-extensions` branch); vanilla opam tops
out at v0.17.1. Trade-off: bleeding-edge and rolling (versions like `v0.18~preview.130.91+190`
move forward under us). `hardcaml_verify` (Phase-8 formal) is installed. `hardcaml_of_verilog`
(yosys → in-process import) needs a one-line workaround on the preview: its `jsonaf` dep's tarball
(`v0.18~preview.130.91+190`) annotates the Faraday serializers `@@ portable`, which is unsatisfiable
(no portable `faraday` exists), so it won't build. A fork drops those 4 annotations (it's parse-only,
never serializes); install via the pin:

```
opam pin add jsonaf.v0.18~preview.130.91+190 \
  'git+https://github.com/zxygentoo/jsonaf.git#528a015' --yes
opam install hardcaml_of_verilog hardcaml_verify --yes
```

plus **`yosys`** (the Verilog import) and **`z3`** (`hardcaml_verify`'s SAT backend) on `PATH` at
runtime — the **`test/formal`** logic-equivalence harness (`@formal`, §6) drives both. (jsonaf is
already fixed upstream in `130.100+614`; the pin is only needed while we track `130.91+190` — bump
the version/commit when the preview rolls forward and the upstream fix lands.) One yosys-version
shim: yosys 0.65 emits cell parameters as binary strings, which the importer's techlib rejects, so
`test/formal` drives yosys itself with `write_json -compat-int` (the library's built-in `Synthesize`
script omits the flag, with no public knob to add it) and feeds the JSON back into its public
`Yosys_netlist.of_string → Netlist → Verilog_circuit` path — no fork of `hardcaml_of_verilog`, and
the patched `jsonaf` still does the parse. RTL fidelity otherwise uses raw **Verilator**
out-of-process (`test/cosim/`, §6). Two compiled-sim backends were evaluated for
Phase-5 boot speed and **both rejected**: `hardcaml_verilator` (Verilator-backed `Cyclesim.t`)
runs on the system Verilator 5.048 but only for **I/O-only** sims — the `__Vscope_*`→`__Vscopep_*`
rename breaks its internal-signal probe (`is_internal_port` / `lookup_*`), which the boot harness
relies on; re-measured 2026-06-26 it's ~4–10× the interpreter (elaboration ~30 s and immovable —
parallel compile and `-O1` don't help; `Cache.Hashed` reload ~0.8 s) but reachable only behind a
`create_debug` rewrite exposing RAM/pc/regs as ports, so still out. `hardcaml_c` (installed,
profiled 2026-06-25) ran only ~3.5× the interpreter while needing minutes to compile its 63 MB /
~1M-line `eval.c` per design change. The boot
checkpoint runs on the **plain Cyclesim interpreter** instead (§6) — fast enough, and it keeps the
full `lookup_*` introspection the harness needs.

- Build on the ox switch: `eval $(opam env --switch 5.2.0+ox --set-switch)` first. The project
  lives on `5.2.0+ox`, **not** `default` (the v0.17.1 install there is unused).
- **Standard library — Jane Street `Base`/`Core` over OCaml's `Stdlib`, minimally.** We're all-in
  on the Jane Street ecosystem (OxCaml, Hardcaml, `ppx_expect`, `qcheck`), so replace `Stdlib` with
  it — but the same minimum-choice rule we apply everywhere applies here too: pull in only what a
  module actually needs. **Default to `Base`** (the lean, portable subset: `List`/`Array`/`Int`/
  labeled-arg APIs); reach for `Core` only where a module genuinely needs its extras
  (`Time`/`Command`/`Unix`/…) — a synthesizable design module rarely will. Open the replacement
  with **`open!`** — it deliberately shadows `Stdlib`'s `List`/`Array`/`=`/comparison and the bang
  says so (silencing warnings 44/45) — and keep library opens (`open Hardcaml`, `open Signal`)
  plain. Hardcaml's signal operators are `:`-suffixed (`+:`, `&:`, `==:`, …), coexisting with the
  shadowed polymorphic `=`/`<`/`compare` (use `==:` for signals, `[%equal]`/typed equals for OCaml
  values). `Base` arrives transitively through Hardcaml, so it needs no `lib/dune` entry; and a
  module that touches no `Stdlib` containers needs no replacement open at all (the shifters/ALU are
  pure Hardcaml). See `registers.ml` for the `open! Base` shape.
- **Module structure — every design module carries an `.mli`** (set alongside the co-located
  tests rule, §6). The `.mli` is the public contract and owns the doc comments; the `.ml`
  keeps implementation notes plus the co-located `let%expect_test`s. Hardcaml interfaces
  re-derive in the signature — `module I : sig type 'a t = { … } [@@deriving hardcaml] end` —
  with the `[@bits N]` width attributes kept in the `.ml` only (widths are values, not part of
  the signature). Inline tests need no signature entry (they register as side effects), so an
  `.mli` and co-located tests coexist. `lib/left_shifter.{ml,mli}` is the reference shape.
- **`docs.hardcaml.org` is authoritative for our API** (it tracks v0.18). Deltas vs. older
  v0.17-era examples found online:
  - Shifts take `~by`: `sll x ~by:n`, `sra x ~by:n`; `log_shift ~f:sll x ~by:sc`
    (`log_shift : f:(t -> by:int -> t) -> t -> by:t -> t`).
  - `select x ~high ~low`, `uresize x ~width`.
  - Int conversions are explicit: `to_int_trunc` / `to_unsigned_int` / `to_signed_int`,
    `of_unsigned_int ~width` / `of_signed_int ~width` (use these instead of v0.17's `to_int`/`of_int`).
  - `mux sel list` and `mux2 sel t f` stay positional; `Signal.input`/`Signal.output` unchanged.
- Hardcaml → Verilog: `Rtl.print Rtl.Language.Verilog circuit`.
- The toolchain wiring (the `oracle` callable on ox, `ppx_hardcaml` interfaces +
  `Cyclesim.With_interface`, `hardcaml_waveterm` waveform render) is now exercised by the real
  suite itself — every FP replay and the CPU lockstep link and call `oracle`, all the `test_*`
  build and simulate Hardcaml circuits, and the lib's co-located `let%expect_test` waveforms drive
  `hardcaml_waveterm`. (The standalone Phase-0 `test_scaffold` smoke that originally certified this
  was retired once those real tests subsumed it.)
- **Running tests.** `dune runtest` = the fast always-on suite (FP replays/fuzz, single-instruction
  CPU lockstep, the lib's co-located inline tests) — a few seconds. Three heavyweight checks are
  **opt-in** (built by `@check` so they can't rot, but kept out of `dune runtest`): `dune build
  @boot_checkpoint` runs the Phase-5 boot-handoff checkpoint (boots the real `.dsk`, ~22 s),
  `dune build @cosim` runs the RTL co-sim (needs Verilator), and `dune build @formal` runs the
  Phase-8 logic-equivalence proofs (needs yosys + z3). `dune build @check` is the
  type-check/pre-commit gate.
- Formatting: `.ocamlformat` is `profile = janestreet` with **no `version` pin** — the ox
  `ocamlformat` reports a git-hash version, so a normal pin (e.g. the emulator's `0.29.0`)
  would mismatch and disable formatting. Format with `dune fmt`.
- Tmp/scratch for this agent: `$CLAUDE_JOB_DIR/tmp`.

### Git workflow (git-flow)

- **`main`** = released state only. **Never commit or merge work directly to `main`.**
  (`AGENT.md`/`CLAUDE.md` live on `develop`; `main` holds only `.gitignore` until a release.)
- **`develop`** = integration branch where phases land; the normal working branch.
- Feature branches: **`feat/<name>`** (note `feat/`, *not* git-flow's default `feature/`),
  via `git flow feature start <name>` / `git flow feature finish <name>`. Other prefixes are
  git-flow defaults (`bugfix/`, `release/`, `hotfix/`, `support/`; empty version-tag prefix).
- Remote `origin` = the GitHub repo (HTTPS, pushes via the stored credential as `zxygentoo`).
- **Pre-commit gate — before every commit run `dune fmt` and `dune build @check`, and fix what
  they flag.** `dune fmt` keeps formatting canonical (janestreet profile); `dune build @check` is
  the batch equivalent of merlin's in-editor diagnostics — it type-checks every module and `.mli`
  and surfaces warnings (which are errors in the dev profile). If a flagged issue isn't reasonable
  to fix — a false positive, a warning from vendored/generated code, or a "fix" that would
  compromise port fidelity (§2) — **stop and notify the human** instead of silently suppressing it.
- Commit messages end with the `Co-Authored-By: Claude …` trailer.

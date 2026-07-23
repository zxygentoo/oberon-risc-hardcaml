# Oberon RISC5 → Hardcaml

A **cycle-accurate, synthesizable Hardcaml port** of Niklaus Wirth's Project Oberon
**RISC5** machine — the OberonStation — on a **Digilent Nexys 4 (Artix-7 XC7A100T)**.
**Built and running**: it boots Project Oberon / Extended Oberon from SD card to the
desktop on real silicon (60 MHz, cached — 2.4× the original) and runs DOOM; every
faithful module is proven equivalent to the original Verilog, and the whole system is
verified against an OCaml emulator (§6).

This file is the **manual**: the sources (§1), the locked design rules (§2–§4), status
(§5), the verification machinery (§6), reference material (§7–§8), and repo/toolchain
mechanics (§9). The phase-by-phase build log is **`build-log.md`**.

---

## 1. The sources

### The Verilog — this is the spec

Not vendored (unclear licensing): `test/fetch-rtl.sh` fetches `OStationVerilog.zip`
(rev. 2015/2018, N. Wirth / P. Reed) on demand into `test/_po/verilog/src/`,
checksum-pinned by `test/rtl-sources.txt`. A pin mismatch means upstream drifted from
the verified revision (§8 cites RTL line numbers); updating the pins is a deliberate
edit of that file.

| File | What it is | Notes |
|---|---|---|
| **`RISC5.v`** (184 L) | **The CPU core** — the crown jewel | single-issue, mostly 1-cycle, stall-based multi-cycle units + interrupts |
| `RISC5Top.OStation.v` | The original SoC | reference for the MMIO map; our SoCs are their own designs (§3) |
| `Registers.v` | Triple-port register file | uses `RAM16X1D` (async read, sync write) — we re-infer, never instantiate |
| `Multiplier.v` / `Divider.v` | Iterative multiply / divide | 33-cycle, state counter + `stall` |
| `LeftShifter.v` / `RightShifter.v` | Combinational barrel shifters | staged 16/8/4/2/1; RShift does ASR+ROR |
| `FPAdder.v` (132 L) | Pipelined FP add/sub (also FLT, FLOOR) | 3-state pipeline |
| `FPMultiplier.v` / `FPDivider.v` | Iterative FP mul / div | 25- / 26-cycle |
| `PROM.v` | Boot ROM (512×32) | the image is baked into the design as `Risc5.Rom` (§9) |
| `RS232R.v` / `RS232T.v` | UART receive / transmit | |
| `SPI.v` | SPI master (SD card + net) | |
| `VID60.v` | Video controller (1024×768×1, DMA from RAM) | drives `stallX` on the core |
| `PS2.v` / `MousePM.v` | PS/2 keyboard / PS/2 mouse | |

Wirth's write-ups — `RISC-Arch.pdf` (ISA encoding; §7 distills it), `RISC.pdf` (the CPU
design), `PO.Computer.pdf` (the board/SoC) — are not kept in the repo; find them on
projectoberon.net (the zip's host).

### Sibling repos

All under [github.com/zxygentoo](https://github.com/zxygentoo/):

- [`oberon-risc-emu-ocaml`](https://github.com/zxygentoo/oberon-risc-emu-ocaml) — **the
  OCaml emulator, our behavioural oracle**, vendored as the `vendor/` submodule (§9).
  `lib/risc.mli` exposes the differential hooks (`cpu_state`, `For_tests.single_step`,
  raw RAM/reg/MMIO access); FP vectors in `test/data/fp_vectors.txt`; also hosts the
  host tools (`run_sim`/`run_dsk`/`run_blob`, `script/mkdsk.sh`, `oat` — the
  serial-channel agent). Hardcaml *is* OCaml, so it plugs in in-process.
- [`oberon-risc-emu-rs`](https://github.com/zxygentoo/oberon-risc-emu-rs) — Rust port;
  its `DIVERGENCES.md` is the emulator-vs-RTL divergence record that §8 distills.
- [`DOOM-on-Oberon`](https://github.com/zxygentoo/DOOM-on-Oberon) — the DOOM port that
  drives the display/performance arcs; its `ABI.md` §11 is the Halftone seam spec (§3).

---

## 2. Locked decisions

Standing principles: **verify every step** — nothing is "done" until its §6 gate is
green, and green gates are the unit of progress; **measure, don't guess** — claims come
from gauges (`test/bench/README.md`); **measure before optimizing** — every performance
change starts from a gauge and ends with a same-work comparison.

1. **Fidelity — faithful where structure *is* the spec, idiomatic where it isn't.**
   `lib/` is a cycle-accurate port of `RISC5.v`, not a fresh behavioral model — but
   "the Verilog is the spec" means its *behavior*, not its syntax. **Mirror the
   sequential skeleton exactly** — which signals are registered, stall/state-counter
   timing, MUL/DIV's 33 cycles, interrupt timing: that's what synthesis preserves and
   what the formal proofs pin to `RISC5.v` (§6). **Be idiomatic Hardcaml in the
   combinational datapath** — shifters, ALU ops, sign-extend, muxes: only the truth
   table is observable there, and synthesis re-maps structure freely. Spend fidelity on
   *timing*, not on transliterating wires — write clean, readable Hardcaml (named
   stages, sub-module outputs by dot-notation, comments for the *why*, never
   line-by-line RTL footnotes). Two surfaces stay fixed: the timing skeleton, and the
   **register names** — the lockstep and the yosys proofs reach state by name
   (`lookup_reg_by_name`, `equiv_make`).

   *What cycle-fidelity buys* (the OCaml oracle is instruction-level — it would pass a
   faster MUL just the same): the **exhaustive** formal equivalence vs `RISC5.v`,
   `RISC5.v` as a **cycle-level debugging oracle**, and the **bright-line discipline** —
   match the RTL exactly ⇒ no per-deviation "is this behavior-preserving?" judgment.
   Departures belong in the board layer (decision 2), never in the faithful default.

2. **Two layers, two contracts.** `lib/` (library `risc5`) is the **faithful port** —
   changes there must keep the co-sim and formal proofs green. Performance and
   architecture extensions — caches, write buffer, framebuffer shadow, Halftone, and
   the default-off seams inside `lib/` (`?fast_mul`, `?mul_stages`, `?baud_*`) — live
   in the **board layer** (or behind those seams) and are judged against the
   **ISA/oracle**: instruction-level lockstep, same-work benchmarks, the goldens, an
   on-hardware boot — not `RISC5.v` timing. The faithful default stays byte-identical;
   never trade it away. (The generalized Phase 9–11 "correct before fast" discipline —
   `build-log.md`.)

3. **Synthesizable** and aimed at the real bitstream (never sim-only).
4. **Board:** Digilent **Nexys 4 (XC7A100T)**, Vivado flow.
5. **Scope:** the **full SoC boots Project Oberon end-to-end** — achieved, and to be
   preserved: an on-hardware boot is the final gate for every board-layer change.
6. **Oracles:** the OCaml `risc_core` emulator (`emu`), in-process — the *behavioural*
   oracle; `RISC5.v` itself (under Verilator / yosys) — the *fidelity* oracle (§6).
7. **Toolchain:** **OxCaml** (opam switch `5.2.0+ox`) + Hardcaml **`v0.18~preview`** —
   chosen so `docs.hardcaml.org` matches our API exactly (vanilla opam stops at
   v0.17.1). Details and v0.18 API notes in §9.

---

## 3. Architecture: portable core + board layer + thin vendor shim

~90% of the design is board-independent synthesizable RTL. Three strict layers, the
separation enforced by one-way library dependencies (`nexys4_board` depends on `risc5`,
never the reverse):

- **`lib/` (library `risc5`) — the faithful machine.** RISC5 core (`cpu.ml` ↔
  `RISC5.v`), the datapath units (+ default-off DSP `?fast_mul` variants, proven
  bit-identical), register file (3R/1W async-read array — Vivado infers distributed
  RAM), all peripherals, boot ROM, and the sim SoC (`soc.ml`: the full `RISC5Top` MMIO
  map over a flat 1 MB single-cycle RAM) — the §6 verification vehicle.
- **`board/nexys-4/` (library `nexys4_board`) — the real-memory SoC**, still
  vendor-free: `cellram` (PSRAM controller + CPU/video arbiter + `?write_buffer` FIFO),
  `cache` (direct-mapped write-through read/I-cache, async LUTRAM, 0-stall
  combinational hit, `?write_update` snoop), `framebuf` (framebuffer BRAM shadow —
  video reads on-chip), `halftone` (the 8bpp dithered-overlay display mode), `soc`, and
  `emit_verilog` (emits `soc_board.v`).
- **`nexys4_top.v` — the only vendor code:** MMCM (100 → 60 MHz system clock, VCO 780;
  → 65 MHz pixel clock), `IOBUF`s (PSRAM data bus, mouse open-drain lines), POR. Pins +
  CDC constraints in `nexys4.xdc` (VGA drives 1-bit mono onto the 12-bit DAC; see the
  in-file notes before touching the CDC constraints).

**The shipped board configuration** — single source of truth
`board/nexys-4/emit_verilog.ml` (each knob carries its rationale as a comment; retune
there): 60 MHz (`fast_mul` + `mul_stages:2` pipelined DSP multiplies made it close),
**16 KiB I-cache** with write-update snoop, framebuffer-in-BRAM, **depth-2 write
buffer**, PSRAM read 6 / write 5 cycles, Halftone on, UART **115200** (both `fsel`
settings), SPI slow divider ÷256 (SD-init ≤ 400 kHz). Running-OS CPI ≈ **1.37** (vs
26.28 uncached — `build-log.md` Phase 10). Memory decode is **24-bit** → the full
16 MiB PSRAM; the [1 MB, 16 MB) himem holds the Halftone window/tables and DOOM's blob.

---

## 4. The Nexys 4 memory reality

- External memory is **16 MiB Cellular PSRAM** (Micron M45W8MW16) with an **async-SRAM
  interface** that self-refreshes — the controller is SRAM-simple (no MIG, no
  refresh/burst machinery). Two mismatches, both handled in `cellram`: a **16-bit** bus
  vs the core's 32-bit word (two halfword accesses; `UB#`/`LB#` carry the byte lanes),
  and **~70 ns** per access — the shipped controller runs 6-cycle reads / 5-cycle
  writes at 60 MHz (the read deliberately one cycle over spec: the tight budget was a
  standing I/O-timing knife-edge), wait-states inserted through the core's existing
  stall path (`ce`).
- Internal **BRAM is ~607 KB** — below Oberon's 1 MB map, so main memory lives in
  PSRAM; BRAM is spent where it pays (the framebuffer shadow, Halftone's RAMs).
- The latency stack — cache, write buffer, shadows — lives **entirely in the board
  layer** (§2.2); the core is untouched. Remaining PSRAM levers are measured and priced
  below their noise (`build-log.md` "further, measured and deferred") — bring numbers
  before reopening them. (Sync 104 MHz burst mode exists; relevant only to DOOM-class
  streaming.)

---

## 5. Status & history

**All phases landed (0–11); the machine is complete and in use.** The build log — each
phase's deliverable, oracle, measurements, and the three optimization-arc narratives —
is **`build-log.md`**. One line each:

| Phase | What landed |
|---|---|
| 0–3 | Scaffold + datapath units: shifters, ALU, register file, MUL/DIV, the three FP units |
| 4 | The CPU core (`RISC5.v`), single-instruction lockstep vs the emulator |
| 5 | Sim SoC + SPI/SD; boot-handoff checkpoint vs the same `.dsk` |
| 6 | All peripherals (cosim-proven) + SoC top; visual golden (byte-identical desktop) |
| 7 | Board layer: PSRAM controller + vendor shim + `.xdc` → **boots on real silicon** |
| 8 | Formal: every datapath unit, the core glue, and the peripherals proven ≡ their `.v` (17 checks) |
| 9 | Compute arc: DSP MUL/FML (`?fast_mul`), pipelined → **60 MHz**; verdict: memory-bound |
| 10 | Memory arc: I-cache + write-update + fb-BRAM + write buffer — running-OS CPI 26.28 → **1.37** |
| 11 | Display arc: `Halftone` — dithered 8bpp overlay at scanout; DOOM 14.1 fps on silicon |

Deeper design logs live next to the code: `board/nexys-4/README.md` (bring-up, PS/2
topology, DOOM cache), `test/formal/README.md` (proof inventory),
`test/bench/README.md` (measurement gauges), `test/cosim/README.md`.

---

## 6. Verification strategy (the pyramid)

**Two oracles, split by the question they answer.** The OCaml emulator (library `emu`)
is the *system-state* oracle: bit-exact architectural state (`pc`/`r[]`/`H`/`flags`) at
*instruction* granularity (its ms-clock is injected; it sees no wire, no cycle) — home:
layers 4–5. The **original Verilog** under **Verilator** (`test/cosim/`) is the
*wire-state* oracle: any signal at *cycle* granularity — the §2 fidelity authority
(layers 3 and 6). They answer orthogonal questions — *is the result correct?* vs *did
we copy the spec?* — and cross-check: every §8 divergence is the emulator differing
from `RISC5.v`, and the co-sim proves our port sides with the RTL.

The layers:

1. **Unit specs** — exhaustive or `qcheck` for combinational blocks, waveform
   expect-tests for the multi-cycle units; co-located in the module's `.ml` (below).
2. **FP vectors** — replay `fp_vectors.txt` through the FP units over the
   *compiler-reachable* domain (FLT/FLOOR always carry the fixed operand `0x4B000000`;
   steer around the §8-divergent forms), plus a fuzz against `Emu.Fp`.
3. **RTL co-sim (fidelity)** — `test/cosim/`: dump the Hardcaml unit's outputs over a
   stimulus set, replay through the reference `.v` under Verilator, assert bit-exact.
   Includes the **boot-stream core co-sim** (capture the core's per-cycle I/O over a
   boot, replay through `RISC5.v`, report the first divergence). The OCaml dumpers
   build under `@check` so they can't rot.
4. **Single-instruction lockstep** — drive random instructions into the CPU sim,
   compare architectural state against `Emu.Risc.For_tests.single_step`;
   `qcheck`-fuzzed, steering around §8. (The interrupt FSM has no oracle — the emulator
   is interrupt-free; it's covered by behavioural waveforms + the formal core proof.)
5. **Boot-level gates** — end-state comparisons, not per-instruction lockstep (which a
   booting machine defeats: the §8 ROM-address skew, the interrupt-free oracle,
   ms-clock and SD/timer poll timing all diverge step-by-step without diverging in
   *result*). On the same `.dsk` as the emulator: the **boot-handoff checkpoint** (run
   to the OS handoff at `pc=0`, ~403 K instructions; compare loaded image +
   architectural state — exact because the handoff is where representations realign)
   and the **visual golden** (boot to the idle desktop; framebuffer byte-identical,
   hash `0xb9bdbf56ba51298d`). Both exist in lib and board variants; the board golden's
   env knobs prove each board feature coherent (`FB_BRAM=1` also asserts shadow ≡
   PSRAM). Board-layer changes add **same-work comparisons** — pc-lockstep two configs
   over an aligned instruction prefix, compare cycles
   (`test/board/nexys-4/bench_boot.ml`).
6. **Formal** — *prove* (not sample) equivalence to the reference `.v`; the exhaustive
   form of layer 3 (`test/formal`). **Combinational**: `hardcaml_of_verilog` import +
   `hardcaml_verify` `Sec` (z3) — needs matching *port* names. **Sequential**: emit our
   Verilog, prove inside yosys — `equiv_make` pairs flip-flops **by name** →
   `equiv_induct`, unbounded induction — which is why lib registers keep RTL names
   (§2). **17 checks, each mutation-checked**: every datapath unit, the register file
   (vs a behavioural spec — `Registers.v`'s `RAM16X1D` idiom has incongruent state),
   the core glue incl. the in-situ ALU (submodules black-boxed, assume-guarantee), and
   all faithful peripherals (the Mouse via an `inout`-split shim; VID partial around
   the one deliberate CDC departure, closed by the `vid_invariant` k-induction property
   proof). Inventory + soundness: `test/formal/README.md`; design history:
   `build-log.md` Phase 8. A new faithful `lib/` unit gets a proof row; a change to a
   proven unit keeps its row green.

**The gates.** `dune runtest` = the fast always-on suite (unit specs, FP replays/fuzz,
lockstep, ROM guard) — a few seconds. `dune build @check` = type-check everything (the
pre-commit gate). The heavyweights are **opt-in** (all built by `@check` so they can't
rot):

| Gate | What it checks | Needs |
|---|---|---|
| `@boot_checkpoint` | sim SoC boots the real `.dsk` to the OS handoff ≡ emulator (~22 s) | — |
| `@boot_checkpoint_board` | the same through the board SoC (PSRAM/cache path) | — |
| `@visual_golden` | sim SoC to idle desktop; framebuffer byte-identical | — |
| `@visual_golden_board` | board SoC golden; knobs `FB_BRAM=1 WRITE_UPDATE=1 WBUF=2 HALFTONE=1` prove the board features do no harm | — |
| `@cosim` | RTL co-sim: FP/peripheral units + the boot-stream core replay | verilator |
| `@formal` | the 17 equivalence/property proofs | yosys, z3 |
| `@bench`, `@profile_boot`, `@bench_boot` | the measurement gauges (index: `test/bench/README.md`) | — |

**Harness — co-locate unit tests; separate harnesses only for system tests.** Module
tests live *inline in the design module's `.ml`* (`ppx_expect` + `qcheck`); reach for
`test/` only when a test couples to the emulator (kept out of `lib` so the design never
depends on the software model) or is a system-level harness. Waveform expect-tests
(`hardcaml_waveterm` render frozen in `[%expect]`; `dune promote` updates) are the tool
for multi-cycle timing — **pin the frozen block**: `~wave_width:4` (the floor that
still renders 32-bit hex) and an explicit `~display_width` (≈70 for 5 cycles;
`left_shifter.ml` is the reference shape), else a rolling `v0.18~preview` bump reflows
the ASCII out from under the `[%expect]`. Use **QCheck** for all fuzz/property tests,
and hoist `Sim.create` out of the property (rebuilding a 1 MB-RAM sim per case once
cost 47 s of runtest). Inline-test deps (`hardcaml_waveterm`, `qcheck-core`) must sit
in `lib`'s own `(libraries)` — `(inline_tests (libraries …))` does *not* cover the
library's compile scope — and they never reach the generated Verilog (`Rtl.print`
lowers the circuit graph, not OCaml deps).

**Cyclesim gotchas (hard-won — check these before debugging a sim).**

- **Registers need `lookup_reg_by_name`**; `lookup_node_by_name` misses them. Silent
  `None`-defaulted lookups read as zeros — use `lookup_node_or_reg_by_name` and fail
  loudly for unconditional probes.
- **Dead-code elimination eats unobserved logic**: anything not reaching a circuit
  output is pruned (the framebuffer shadow BRAMs once vanished because only `sclk` was
  exposed). Keep the observed path live — `Board_tb.O` carries `hsync`/`vsync`/`rgb`
  for exactly this.
- **`Cyclesim.outputs` defaults to after-edge sampling** (`after(k) = before(k+1)`):
  input-driven pulses are invisible there; sample `~clock_edge:Before` for the core's
  view.
- **One clock domain**: pclk-side logic advances 1:1 with `clk` whatever the pclk
  *input* does — video DMA is live in every board sim, so honest A/B experiments need
  elaboration-time gates (e.g. `?video` on `vidreq`). Async-set CDC must be modeled
  explicitly (reset is edge-sampled). Waveterm is unreliable across domains — use
  text-table expects; `By_input_clocks` gives native multi-clock.
- **Async-memory reads settle at `after_clock_edge`** — assert post-edge after a full
  cycle, not at `before_clock_edge`.

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
  The OCaml oracle and the Rust port both follow the hardware (OCaml `risc.ml:335`, Rust
  `risc.rs:542`, guard test `mov_flags_read_0x53`); only the C reference (Peter De Wachter's
  upstream `pdewacht/oberon-risc-emu`) still emits `0xD0`, and C isn't our oracle — the OCaml
  lockstep oracles this byte *directly*, no steering needed. Principle to keep regardless:
  **our Verilog is the spec.** See the Rust port's `DIVERGENCES.md` (§1).
- **`ADD'/SUB'` carry with carry-in (the one remaining lockstep steer-around).** `RISC5.v`'s
  adder computes C/V from the real sign bits (lines ~161–166); the OCaml oracle derives C by
  comparison (`risc.ml:353`, `s < b`) and misses one corner (2nd operand `0xFFFFFFFF` with
  carry-in). We follow the hardware — the fuzzer steers around this case. (Unreachable from
  Oberon-07 compiled code anyway.)
- **Unsigned `MUL'` high word (a lockstep steer-around).** `Multiplier.v` sign-extends
  its *second* operand unconditionally (`{w0[31], w0}`, line 16); the module's `u` flag (driven
  `~u`, so `u=1`≡signed) controls *only* the MSB subtract, which flips the *first* operand's
  sign. So unsigned `MUL'` computes `B_unsigned × C1_signed`, whereas both emulators compute
  `B_unsigned × C1_unsigned` (OCaml `risc.ml:371`, C `risc.c:279`). The low 32 bits always
  agree; only `H` differs, and only when `C1[31]=1` — the fuzzer steers around that case in
  unsigned-`MUL` lockstep. (Reachable only via an `H`-read after `MUL'`.)
- **FP FLT/FLOOR denormalize sign-fill (a co-sim non-issue; an FP-vector steer-around).**
  `FPAdder.v` fills its denormalize right-shift with the operand *sign bit*, while the C/OCaml
  model arithmetic-shifts the two's-complement *value* — they differ only for a
  negative-zero-mantissa operand being shifted, which surfaces only in FLT/FLOOR. Unreachable
  in compiled code: the compiler (`ORG.Mod` `Float`/`Floor`) fixes the FLT/FLOOR 2nd operand
  to `0x4B000000` (2^23), so no divergent shift occurs. Our port follows the hardware, verified
  bit-exact to `FPAdder.v` over 26k stimuli; the FP-vector replay (§6) steers around the
  non-`0x4B000000` forms.
- **Addressing.** `RISC5.v` uses a 20-bit RAM window (out-of-range aliases into 1 MB) + a
  22-bit word PC; emulators decode 32 bits. Identical for well-behaved software; the divergence
  is confined to *code addresses*: the oracle's ROM base (byte `0xFFFFF800`, pc word
  `0x3FFFFE00`) differs from `RISC5.v`'s (`StartAdr` word `0x3FF800`), so `pc` and `R15` links
  differ by a constant offset *while running from ROM*. Data addresses and **all low-RAM code
  are bit-identical**, so it self-heals once the OS runs from low RAM — which is why boot is
  verified by end-state checkpoints, not per-instruction lockstep (§6 layer 5).
  *(Shipped-board note: the board layer widens data decode to 24 bits — the full 16 MiB PSRAM
  — and the OCaml emulator matches at 16 MiB; the ROM-offset skew above is unchanged.)*
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
  AGENT.md / CLAUDE.md    ← this manual (CLAUDE.md is a symlink to AGENT.md)
  build-log.md            ← the phase-by-phase build log
  dune-project, dune      ← root build config (dune restricted to: lib board test vendor)
  lib/                    ← design library `risc5` — the faithful machine (§3). Every
                            module: .mli + co-located inline tests; the .ml header names
                            the RTL file it ports.
  board/
    nexys-4/              ← Nexys 4 target = library `nexys4_board`:
      cellram, cache, framebuf, halftone, soc   the board design (§3), each .ml+.mli
      cellram_model           sim double of the PSRAM chip (test-only, never synthesized)
      emit_verilog.ml         emits soc_board.v — THE shipped-config record (§3)
      nexys4_top.v            vendor shim: MMCM/IOBUF/POR (the ONLY vendor code)
      nexys4.xdc              pins + CDC constraints
      build/program/flash.tcl, gen_verilog.sh   Vivado emit → synth → program flow
      Mod/                    Oberon-side drivers/demos (Halftone.Mod, Mandel.Mod)
      README.md               board design log (bring-up, PS/2 topology, DOOM cache)
    _generated/<target>/  ← git-ignored: emitted soc_board.v
    _build/<target>/      ← git-ignored: Vivado runs + the bitstream
  test/                   ← fast suite (test_fp_*, test_cpu_lockstep, test_rom) + the
                            opt-in system gates (test_boot_checkpoint, test_visual_golden)
    board/nexys-4/        ← board-SoC gates + bench_boot, sharing the board_tb harness
    bench/                ← target-independent gauges; its README.md indexes all gauges
    cosim/                ← RTL co-sim (Verilator): unit dumps + the boot-stream core replay
    formal/               ← equivalence/property proofs; proofs/ = .ys templates
    fetch-rtl.sh, rtl-sources.txt   ← fetch + checksum-pin the reference .v
    _po/                  ← fetched originals, git-ignored (verilog/src/*.v only)
    _work/                ← test scratch, git-ignored; safe to delete
  vendor/
    oberon-risc-emu-ocaml/  ← git submodule: the OCaml emulator, pinned
    emu/                    ← builds the submodule's lib/ as library `emu`
```

**Emu wiring.** The submodule's `risc_core` is private behind its own `dune-project`,
so `vendor/emu/dune` `copy_files` its `lib/` sources and builds them as library
**`emu`** (warnings off; only dep `unix`) — self-contained, submodule pristine. The
boot ROM lives in the design as `Risc5.Rom`; the emulator keeps its own `Emu.Boot_rom`,
and `test/test_rom.ml` pins the two equal — design and emulator can never boot
different images.

**Toolchain.** **OxCaml** — opam switch **`5.2.0+ox`**, dune `3.22+ox`, Hardcaml
**`v0.18~preview`** (+ `ppx_hardcaml`, `hardcaml_waveterm`, `hardcaml_verify`). We
track the preview on purpose — `docs.hardcaml.org` documents exactly this build — and
it rolls forward under us. `opam install hardcaml_of_verilog hardcaml_verify --yes`
installs the proof stack — plain upstream: the forked-`jsonaf` pin the preview once
needed (unsatisfiable `@@ portable` annotations in its tarball) became unnecessary at
`130.100+614` and was dropped 2026-07 on the roll-forward to `130.106+341` (all gates
re-proven).

Runtime deps for the opt-in gates: **verilator** (`@cosim`), **yosys** + **z3**
(`@formal`). Two version shims. yosys 0.65 emits binary-string cell parameters the
importer rejects — `test/formal` drives yosys with `write_json -compat-int` and feeds
the JSON through the public `Yosys_netlist.of_string` path (no fork). ppx_expect
≥ `130.100` resolves expect-test sources as `<source-tree-root>/<basename>` while
dune's inline-tests backend passes `%{workspace_root}` — the directory component is
lost and every inline-tests library in a subdirectory crashes at exit
(`Sys_error "../foo.ml"`); each such library re-points the root at its own dir with
`(inline_tests (flags -source-tree-root .))` (see `lib/dune`; drop when upstream
re-agrees). Compiled-sim
backends (`hardcaml_c`, `hardcaml_verilator`) were evaluated and **rejected** — modest
speedups at the cost of multi-minute recompiles or the `lookup_*` introspection the
harnesses live on; the boot gates run the plain Cyclesim interpreter (~0.39 M cycles/s).
Don't revisit without new evidence.

- Build on the ox switch: `eval $(opam env --switch 5.2.0+ox --set-switch)` first. The
  project lives on `5.2.0+ox`, **not** `default`.
- **Standard library — Jane Street `Base` over `Stdlib`, minimally.** Default to `Base`
  (`Core` only when a module genuinely needs its extras), opened with **`open!`**;
  library opens (`open Hardcaml`, `open Signal`) stay plain. `==:` for signals,
  `[%equal]`/typed equals for OCaml values. `Base` arrives transitively through
  Hardcaml; a module touching no `Stdlib` containers needs no open at all.
  `registers.ml` is the reference shape.
- **Every design module carries an `.mli`** — the public contract owns the doc
  comments; the `.ml` keeps implementation notes + co-located tests. Hardcaml
  interfaces re-derive in the signature; `[@bits N]` widths stay in the `.ml`.
  `lib/left_shifter.{ml,mli}` is the reference shape.
- **Module naming — role-based** (`cpu.ml`, `uart_rx.ml` — the library reads as the
  machine's anatomy), never 1:1 after the Verilog file names; §2 binds *behavior and
  register names*, never file names. Two deliberate exceptions: `cellram` (names the
  actual chip) and the emitted Verilog module `soc_board` (the Vivado flow binds it).
  Gotcha: `open Hardcaml` shadows the bare `Ram`/`Rom` sibling names inside `lib/` —
  bind before the opens, rebind after (`lib/soc.ml`'s `Machine_ram` dance).
- **`docs.hardcaml.org` is authoritative for our API** (v0.18). Deltas vs older
  v0.17-era examples online: shifts take `~by` (`sll x ~by:n`, `log_shift ~f:sll x
  ~by:sc`); `select x ~high ~low`, `uresize x ~width`; explicit int conversions
  (`to_int_trunc`/`to_unsigned_int`/`to_signed_int`, `of_unsigned_int ~width`/
  `of_signed_int ~width`); `mux`/`mux2` stay positional. Hardcaml → Verilog:
  `Rtl.print Rtl.Language.Verilog circuit`. Since preview `130.106` waveform capture
  lives in core Hardcaml — `Cyclesim.Waveform.create sim` returns the `Wave_data.t`
  that `Hardcaml_waveterm.Waveform.print` renders (`Hardcaml_waveterm.For_cyclesim`
  is gone), and rendered signal order follows interface declaration order (was
  alphabetical — a one-time reflow of frozen waveform expects).
- **Running tests:** `dune runtest` (fast suite, seconds); opt-in gates per the §6
  table; `dune build @check` = the type-check/pre-commit gate. NB `@check`
  type-checks but does **not** link the gate executables — `dune exec` (or
  `dune build <path>.exe`) before running one from `_build` by hand.
- **Fast gate iteration — `SPI_DIV_LOG2=2`:** all four boot gates take this env knob
  (rides {!Spi}'s existing `?slow_div_log2` seam, guarded floor 2 = clk÷4). The boot
  is ~80% *slow-mode SPI wait* at the faithful clk÷64, so the knob cuts the
  checkpoints ~4× (35 s → ~9 s) and, with the goldens' oracle-hash early-exit
  (automatic), the goldens ~1.7× (sim 2m47s → 1m38s; board shipped-knobs 7m15s →
  4m23s). End states are divider-independent (validated byte-identical, and SPI
  itself is `@formal`-proven). Knob **unset = the faithful ÷64, cycle-exact to the
  historical runs** — keep at least one knob-unset run in pre-merge/release rituals.
  (Record + probe numbers: `build-log.md` postscript.)
- Formatting: `.ocamlformat` is `profile = janestreet` with **no `version` pin** (the
  ox `ocamlformat` reports a git-hash version; a pin would mismatch and disable
  formatting). Format with `dune fmt`.
- Tmp/scratch for this agent: `$CLAUDE_JOB_DIR/tmp`.

### Git workflow (git-flow)

- **`main`** = released state only. **Never commit or merge work directly to `main`.**
  (Releases merge from `develop`; the first landed 2026-07.)
- **`develop`** = integration branch; the normal working branch.
- Feature branches: **`feat/<name>`** (note `feat/`, *not* git-flow's default
  `feature/`), via `git flow feature start/finish <name>`. Other prefixes are git-flow
  defaults; empty version-tag prefix.
- Remote `origin` = the GitHub repo (HTTPS, pushes as `zxygentoo`).
- **Pre-commit gate — run `dune fmt` and `dune build @check` before every commit, and
  fix what they flag.** If a flagged issue isn't reasonable to fix — a false positive,
  vendored/generated code, or a "fix" that would compromise port fidelity (§2) — **stop
  and notify the human** instead of silently suppressing it.
- Commit messages end with the `Co-Authored-By: Claude …` trailer.

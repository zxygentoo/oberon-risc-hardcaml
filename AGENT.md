# Oberon RISC5 → Hardcaml

A **cycle-accurate, synthesizable Hardcaml port** of Niklaus Wirth's Project Oberon
**RISC5** machine — the OberonStation FPGA system — targeting a **Digilent Nexys 4 DDR
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

Everything lives under `po/` (originals) and the three sibling emulator repos.

### The Verilog — this is the spec
`po/verilog/src/` (extracted from `po/OStationVerilog.zip`, rev. 2015/2018):

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
| `RISC5.OStation.ucf` | Pin constraints (Spartan-3) | we rewrite as a Nexys 4 DDR `.xdc` in Phase 7 |

Boot ROM image: `po/verilog/prom.mem` (hex) + `po/verilog/prom.bmm`.

### The docs
- `po/RISC-Arch.pdf` (3 pp) — **ISA encoding** (the cheat sheet in §7 is distilled from this).
- `po/RISC.pdf` (24 pp) — Wirth's detailed design writeup.
- `po/PO.Computer.pdf` (21 pp) — the board/SoC overview.

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

   *What cycle-fidelity is — and isn't — for.* The OCaml oracle is **instruction-level** (its
   ms-clock is injected via `set_time`, not cycle-derived; it steps by instruction), so it
   proves *behavioral* correctness and needs **no** cycle-accuracy — both lockstep levels (§6)
   would pass a faster MUL just the same. Cycle-accuracy earns its keep on three *other* counts:
   the **exhaustive** Phase-8 equivalence proof vs `RISC5.v` (catching rare corners that
   sampling misses), `RISC5.v` as a **cycle-level debugging oracle** through the hard core/SoC
   phases, and the **bright-line discipline** (match the RTL exactly ⇒ no per-deviation "is this
   behavior-preserving?" judgment, nothing hiding in the oracle's blind spots). Trading these
   away for idiom or speed is deliberately deferred to Phase 9 (§5).
2. **Synthesizable** and aimed at a real bitstream (not sim-only).
3. **Board:** Digilent **Nexys 4 DDR (XC7A100T)**, Vivado flow.
4. **Scope:** the **full SoC that boots** Project Oberon end-to-end.
5. **Memory:** build the **faithful shared single-port RAM + video-DMA stall** design first
   (free & exact in simulation); the **DDR2 memory adapter** is a **deferred refactor** for
   board bring-up (see §4 — it's mandatory on *this* board, not optional).
6. **Oracle:** the OCaml `risc_core` emulator, in-process, plus its FP vectors + boot ROM.
7. **Toolchain:** **OxCaml** (opam switch `5.2.0+ox`) + Hardcaml **`v0.18~preview`** — chosen so
   the official `docs.hardcaml.org` matches our API exactly (it documents the OxCaml/preview
   build; vanilla opam stops at v0.17.1). Details and v0.18 API notes in §9.

---

## 3. Architecture: portable core + thin board shim

~90% of the design is **board-independent synthesizable RTL**; only a thin top-level shim
touches vendor primitives. Keep this separation strict.

**Board-independent (simulated *and* lockstep-verified):** RISC5 core, ALU, barrel
shifters, iterative MUL/DIV, the three FP units, the register file (as a normal 3R/1W
async-read array — let Vivado infer distributed RAM, don't instantiate `RAM16X1D`), and
all peripheral logic (RS232 R/T, SPI, PS/2, mouse, VID controller, MMIO decode).

**Board shim (the only Xilinx-specific layer, Phase 7):**
- **Clock:** original `DCM_SP ×5/÷12` (60→25 MHz) → Nexys `MMCM` 100→25 MHz. 25 MHz is a
  very relaxed target — timing closure is easy.
- **Main memory + video DMA:** the DDR2 adapter (see §4).
- **IO pads:** `IOBUF` for genuinely bidirectional pins (gpio, mouse `msclk`/`msdat`);
  `ODDR` only if a DDR output trick survives. The original `ODDR2`/SRAM-`IOBUF` write
  path disappears once memory is DDR2-backed.
- **Pins:** VGA (drive 1-bit mono onto the 12-bit DAC), PS/2, microSD (SPI), UART → `.xdc`.

---

## 4. The Nexys 4 DDR memory reality (important)

The board is a great I/O match for the OberonStation (12-bit VGA, PS/2 via USB-HID bridge,
microSD/SPI, USB-UART, 100 MHz), **but its memory does not match**:

- External memory is **128 MiB DDR2** — needs the Xilinx **MIG** controller, has
  latency/refresh/bursts, and **cannot** be driven as the single-cycle async SRAM that
  `RISC5Top` assumes. (The older non-DDR Nexys 4 had async PSRAM; the DDR rev dropped it.)
- Internal **BRAM is only ~607 KB** (4,860 Kbit) — **below** Oberon's standard **1 MB** map
  (the framebuffer sits at `0xE7F00–0xFFEFF`, the top ~98 KB of that 1 MB). So the full
  faithful memory can't live in BRAM on the `100T`.

**Consequence & why deferral is safe:** all verification happens in *simulation*, where a
flat 1 MB BRAM model makes the faithful shared-RAM design exact and free. On the bitstream,
the memory layer is the one place that must adapt — a DDR2-via-MIG adapter fronted by a
cache/line-buffer that **presents the same SRAM-like interface and inserts wait-states
through `RISC5.v`'s existing stall path**. The CPU core stays byte-for-byte unchanged, so
nothing in Phases 0–6 depends on how memory is eventually backed.

*(If zero memory refactor were ever a priority, an Artix `200T`-class part has ~1.6 MB BRAM
— enough to hold the whole 1 MB internally. We're keeping the Nexys 4 DDR.)*

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
| **3b** | `FPAdder`/`FPMultiplier`/`FPDivider` (+ FLT/FLOOR) | frozen `fp_vectors.txt` |
| **4** | **CPU core** = PC/IR + control unit + stall aggregation + interrupts + N/Z (from `regmux`) | **single-instruction lockstep** vs `Oracle.Risc.For_tests.single_step`, fuzzed (steering around §8) |
| **5** | Memory + minimal SoC harness; run boot ROM | **full-boot lockstep** (`hardcaml_c` for speed) |
| **6** | Peripherals + SoC top; framebuffer out | boot golden + visual |
| **7** | **Board shim:** `MMCM`, `IOBUF`/`ODDR`, **DDR2-via-MIG adapter**, VGA/PS2/SD pins, `.xdc` → **bitstream** | on-hardware boot |
| **8** *(stretch)* | `hardcaml_of_verilog` import of `RISC5.v` + `hardcaml_verify` bounded equivalence | formal proof |
| **9** *(stretch)* | **Optimization pass** — from the verified-correct, Phase-8-proven baseline, make it faster / more idiomatic: DSP-backed `*:`/`*+` for MUL/DIV, pipelining, idiomatic rewrites, dropping iterative stalls where behavior-preserving | architectural lockstep only (instruction-level state + full-boot: Oberon still boots & runs); cycle-accuracy & formal eq vs `RISC5.v` intentionally relaxed |

*Correct before fast (Phase 9).* Phases 0–8 hold the cycle-accurate mandate (§2), which keeps
`RISC5.v` a *total* oracle — a bright line that keeps the spec unambiguous and bugs findable. Phase 9
is the one place we deliberately cross it, only *after* the faithful port is verified (and formally
checked in 8): optimizations there are judged against the **ISA/oracle** — does Oberon still boot and
lockstep at the instruction level — not against `RISC5.v` timing. Work from a tagged faithful baseline
(e.g. a `feat/fast-mul` spike), so the proven port is never lost.

---

## 6. Verification strategy (the pyramid)

Each layer's oracle already exists next door — this is our biggest leverage.

1. **Unit specs** — exhaustive or `qcheck` for combinational blocks (shifters, ALU).
2. **FP vectors** — replay `fp_vectors.txt` through the FP units.
3. **Single-instruction lockstep** — drive random instructions into the Hardcaml CPU sim,
   compare architectural state (`pc`, `r[]`, `h`, `flags`) against `Oracle.Risc.For_tests.single_step`.
   `qcheck`-fuzzed, exactly like the OCaml repo's `test/cosim/test_cosim_cpu.ml`.
4. **Full-boot lockstep** — load `prom.mem` + disk image, run both machines for millions of
   cycles, compare CPU state / framebuffer. Use a fast sim backend (`hardcaml_c`).
5. *(stretch)* **Formal** — combinational/bounded equivalence between our port and the
   imported `RISC5.v` via `hardcaml_verify`.

**Harness — co-locate genuine unit/module tests; keep a separate harness only for
system-level tests.** Co-location is the default — reach for `test/` only when a test *can't* sit
in `lib`: it couples to the emulator oracle (the dep we deliberately keep out of `lib`), or it's a
system-level harness (full-boot, the Phase 0 scaffold). Module tests live *inline in the design
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
(single-instruction lockstep Phase 4, full-boot Phase 5) live in `test/` (depending on `risc5` +
`oracle`), so the synthesizable design never depends on the software model. `lib/dune` carries
`(inline_tests)` + `(preprocess (pps ppx_hardcaml ppx_expect))`; the Phase 0 `test_scaffold` smoke
stays in `test/`.

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
- **Addressing.** FPGA uses a 20-bit address bus (out-of-range aliases into 1 MB); emulators
  decode 32 bits. Identical for well-behaved software.
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
  dune-project, dune      ← root build config (dune restricted to: lib test vendor)
  lib/                    ← Hardcaml design library `risc5` (placeholder in Phase 0;
                            real modules — shifters, ALU, CPU core… — from Phase 1)
  test/                   ← tests (`test_scaffold` = the Phase 0 wiring smoke)
  vendor/
    oberon-risc-emu-ocaml/  ← git submodule: the OCaml emulator/oracle, pinned
                              (data_only_dirs: dune ignores its own project files)
    oracle/               ← compiles the submodule's lib/ into library `oracle`
                            (Oracle.Risc, Oracle.Fp, Oracle.Boot_rom, …)
  po/                     ← original sources, git-ignored: verilog/src/*.v,
                            verilog/prom.mem, *.pdf
```

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
move forward under us). `hardcaml_c` / `hardcaml_of_verilog` / `hardcaml_verify` get added on
ox when their phases arrive (confirm availability then).

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
- Verified end to end by `test/test_scaffold.ml` (`dune test`): `oracle` (`Oracle.Risc`)
  callable on ox, `ppx_hardcaml` interfaces + `Cyclesim.With_interface` (sim `0xFF<<4=0xFF0`),
  and a `hardcaml_waveterm` waveform render of a counter.
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

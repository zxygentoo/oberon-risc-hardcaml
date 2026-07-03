# `test/formal` — logic-equivalence proofs vs the reference Verilog

The **Formal** layer of the verification pyramid (AGENT.md §6). Where [`test/cosim`](../cosim)
*simulates* a unit against its reference `.v` and samples (Verilator), this *proves* the two
compute the identical function — **exhaustively, over every input / for all states**.

Two modes, because combinational and sequential equivalence want different tools:

### Combinational — `formal_equiv.ml` (import + `Sec` + z3)

```
ours: Risc5.Left_shifter (log_shift, radix-2) ─┐
                                               ├─ Sec.create → CNF → z3 → UNSAT = equivalent
LeftShifter.v (Wirth, radix-4 mux tree) ───────┘
```

- **Import** the reference `.v` to a `Hardcaml.Circuit.t` via `hardcaml_of_verilog` (yosys).
  We drive yosys with `write_json -compat-int` (yosys 0.65 emits cell params as binary
  strings, which the importer's techlib rejects) and feed the JSON into its public
  `Yosys_netlist.of_string` path — no fork (see `formal_equiv.ml`).
- **Prove** with `hardcaml_verify`'s `Sec` (a miter SAT-checked by **z3**). Requires only the
  *port* names to match. Complete for the datapath blocks that have a standalone `.v`.

### Sequential — `yosys_equiv.ml` (emit + yosys `equiv_induct`)

```
ours: Risc5.Multiplier (S/P state) ─emit→ gate.v ─┐
                                                  ├─ equiv_make → equiv_induct → all $equiv proven
Multiplier.v (Wirth, 33-cycle shift-add) ─────────┘
```

`Sec` is combinational and pairs registers *by name*; through the import path the registers
come back mangled/regrouped, so it can't pair them. Instead we **emit our circuit to Verilog**
(`Rtl`) and prove it equivalent to the `.v` *inside yosys*: `equiv_make` pairs flip-flops by
name, `equiv_induct` proves the step by temporal induction (an *unbounded* proof — it covers
the 33-cycle datapath for all states, not a bounded trace). Needs only **yosys** (built-in SAT)
— no import, no z3.

Requirement: the *port and register* names must match the reference's, so `equiv_make` can pair
the state. Hence the sequential units name their registers after the RTL (e.g. the Multiplier's
`S`/`P`), and the driver builds the circuit with ports named to match the `.v`.

### Behavioural spec — the register file (`registers_spec.v`)

```
ours: Risc5.Registers (one 16x32 array) ─emit→ gate.v ─┐
                                                       ├─ memory → equiv_make → equiv_induct ✓
registers_spec.v (behavioural: 16x32, 3R/1W) ──────────┘
```

The one unit proven **not** against its Wirth original. `Registers.v` builds the triple-port
file from 64 *duplicated, bit-sliced* `RAM16X1D` distributed-RAM primitives — a synthesis idiom
for getting a 3rd async read port out of 2-read-port LUT RAM. Its bit-sliced + duplicated state
(1024 bits) is structurally incongruent with our single 16×32 array (512 bits): `equiv_make` has
no flip-flops to pair, and a memory miter isn't inductive on outputs alone (an unread location
can differ in an unreachable state — empirically only a *shallow bounded* check is tractable
there). This is the canonical §2/§3 "structure is not the spec" case, so we prove our `Registers`
against the behavioural **contract** instead (`registers_spec.v`: 16×32, three async reads, one
sync write). Both sides are a single array, so the shared sequential script's `memory` pass lowers
them to flip-flops that pair by name and `equiv_induct` closes (unbounded). That Wirth's
`RAM16X1D` duplication implements the same contract is *his* synthesis concern (Vivado's
distributed-RAM inference), not ours.

### In-situ core glue — `core_blackbox.ml` + `proofs/core.ys.template` (assume-guarantee)

```
RISC5.v (gold) ──────┐  8 units = black boxes on both sides (core_stubs.v)
                     ├─ equiv_make (merge units, check inputs) → cutpoint -blackbox
Cpu (gate) ──────────┘     → equiv_simple + equiv_induct → all $equiv proven
  via create_with_units (Core_blackbox.units = Instantiation stubs)
```

The whole core proven against `RISC5.v` — **except** its 8 submodules, which are black-boxed
and *assumed* equivalent (sound: each is proven separately above — 7 vs their `.v`, the
register file vs its contract). What's left, and what this proves, is the **glue**: decode,
the **inline ALU (`aluRes` — no standalone `.v`, finally proven in-situ)**, the control unit
(`pcmux`/`cond`), the flag logic, and the 13 state registers (`PC`/`IR`/flags/`H`/`stallL1`/
interrupt state).

The seam is `Cpu.create_with_units`: `Core_blackbox` passes `Instantiation` stubs whose
module / instance / port / **output-wire** names match `RISC5.v` (so `equiv_make` pairs them).
The flow (`proofs/core.ys.template`): rename our registers to the RTL's → `equiv_make` (pairs the top
flip-flops and *merges* the matched black-box cells, checking their **inputs** via the `$equiv`
on the named nets) → **`cutpoint -blackbox`** (replaces the merged units with shared free
signals — the *assume* side) → `equiv_simple` + `equiv_induct` on the resulting pure-glue
netlist. This is the standard assume-guarantee decomposition; it's sound here because no
combinational path crosses a submodule boundary (every unit sits behind a clocked or
non-looping interface), so the core genuinely decomposes into glue + proven leaves.

*Teeth (verified):* mutating one bit of the reset vector in the gate leaves exactly 2 `$equiv`
unproven — `PC[0]` and `adr[2]` (= `PC<<2`) — so the proof catches glue bugs and localizes
them; it is not vacuous.

## The driver — one `run_proof` + per-proof `.ys.template`

Every yosys-backed proof above — the ten single-clock units *and* the core/mouse/vid/vid_invariant
one-offs — runs through a single driver, `Yosys_equiv.run_proof`. The proof *tactic* (the actual
yosys commands) lives in a checked-in template under [`proofs/`](proofs), beside the `.v` it reads.
`run_proof` emits our circuit to Verilog, substitutes `{placeholder}` → value into the template
(the `.v`/spec paths, the top/gate module names, any rename block — plus the harness-owned `{ours}`/
`{gate}`/`{smt2}`), writes the **concrete** script to `test/_work/formal/<check>/proof.ys`
(inspectable *and* runnable), runs yosys, and maps the exit code. The one property proof
(`vid_invariant`) adds a `yosys-smtbmc` step via `~smtbmc` (yosys only emits the SMT problem there;
the verdict is the k-induction). A leftover `{…}` after substitution raises — a real yosys command
never contains a brace, so any survivor is an unfilled placeholder.

So a proof is its `proofs/*.ys.template` (read it to see exactly what yosys does) plus a few lines of
OCaml supplying the data. The shared `sequential.ys.template` serves all ten single-clock units;
`core`/`mouse`/`vid`/`vid_invariant` each have their own template for their bespoke tactic
(black-boxing, the open-drain shim, the CDC cut, the SMT property). *Only* the combinational shifters
sit outside this — they use `hardcaml_verify`'s `Sec`/z3 (`formal_equiv.ml`), no yosys, no template.

## Running

Opt-in (like the cosim) — needs **yosys** on `PATH` (both modes) and **z3** (combinational
mode), plus the `hardcaml_verify` / `hardcaml_of_verilog` libraries (AGENT.md §9):

```
dune build @formal                              # prove every unit, in parallel
dune exec test/formal/formal_run.exe -- core    # one check, live (e.g. core | vid_invariant |
                                                #   left_shifter | multiplier | mouse | …)
dune exec test/formal/formal_run.exe -- all 4   # all, capping parallelism at 4 jobs
```

`formal_run` is a self-contained OCaml runner (like cosim's `cosim_run`): it cd's to the repo
root, checks `yosys`/`z3` on `PATH`, fetches + checksum-verifies the reference Verilog on demand
(toolchain-free [`../fetch-rtl.sh`](../rtl-sources.txt), shared provenance with the cosim), then
runs the checks through the shared parallel `Fork_pool` — each in its own
`test/_work/formal/<check>/`, output captured to `run.log` — ending with a PASS/FAIL summary.
yosys/z3 are RAM-heavy, so it defaults to ~half the cores; pass a job count to override.

## Adding a unit

In `formal_run.ml`:
- **Combinational** (standalone `.v`, no state): add a row to `combinational` — a thunk building
  the circuit via `Circuit.With_interface (Unit.I) (Unit.O)` (ports match the `.v`), plus the
  reference `.v` + top-module name.
- **Sequential**: ensure every register is *named* in `lib/` (so `equiv_make` can pair it — an
  unnamed reg gets a generated name nothing can pair against), then add a row to `sequential` — a
  thunk building the circuit with `Circuit.create_exn`, ports named to match the `.v` (module name
  *distinct* from the reference, since yosys reads both), and a `renames` list mapping any lib reg
  names that differ from the RTL's to the `.v`'s (applied in yosys, like the core's
  `register_renames`; `[]` when they already match). Keep the lib's waveform/SoC-namespaced names
  and rename here — e.g. `q0→Q0`, `spi_shreg→shreg`.
- **Behavioural spec** (a unit whose RTL is a synthesis idiom, not behaviour — so far only the
  register file): add a checked-in `*_spec.v` under `proofs/`, a thunk, and a row to `behavioral`
  (reference dir is `proofs_dir = test/formal/proofs`, not the fetched `test/_po/`). Same
  `sequential.ys.template` / `equiv_induct` path.

Each one-off is its own runner (not a list row) + its own `proofs/<name>.ys.template`:

- **In-situ core** (whole core, submodules black-boxed): see `core_blackbox.ml` (the gate, via
  `Cpu.create_with_units`), `proofs/core_stubs.v` (the stubs), and `run_core` +
  `proofs/core.ys.template` (the `cutpoint`-based flow).
- **Open-drain shim** (a unit whose RTL has bidirectional `inout` pins our port splits into
  `*_oe`+resolved-input — so far only the Mouse): see `proofs/mouse_shim.v` (the two wrappers) and
  `run_mouse` + `proofs/mouse.ys.template` (wrap both sides into one explicit interface, lower the
  tristate with `tribuf -formal`/`chformal -remove`/`setundef -one`, then `equiv_induct`).
- **Multiclock + CDC cut** (a two-clock unit with a deliberate CDC departure — so far only VID): see
  `proofs/vid_stubs.v` (DCM/BUFG stubs) and `run_vid` + `proofs/vid.ys.template` (drop the DCM +
  `expose -input pclk`, `expose -input` the CDC boundary signal to a shared free input on both sides,
  and `equiv_remove` the departed output). A *partial* proof by construction — proves around the CDC.
- **Temporal property** (a claim that's *not* a cycle-equivalence — so far the VID fetch invariant):
  see `proofs/vid_invariant.v` (a monitor wrapping the emitted gate with assumptions + assertions)
  and `run_vid_invariant` + `proofs/vid_invariant.ys.template`, run with `~smtbmc` (the template emits
  the SMT problem: emit → `clk2fflogic` → `write_smt2`; then `yosys-smtbmc -i -s z3 -t <k>`,
  k-induction — the engine SymbiYosys wraps, no `sby` needed). An unbounded proof over all clock
  interleavings; use when there's a property to prove but no equivalence.
- **Combinational vs a Hardcaml spec** (a unit with no reference `.v` — so far the VID look-ahead
  address): build both the real logic and an independently-written *spec* as in-process Hardcaml
  circuits with matching port names, and `Formal_equiv.check_circuits ~ours ~spec` SAT-checks them
  with z3 (no `.v` import, no yosys). See `vid_addr_ours` / `vid_addr_spec` + `run_vid_addr`. Use when
  the property is combinational but there's no Wirth original to import (the spec is the contract, like
  `registers_spec.v` but written in Hardcaml).

The datapath + core layer is closed: both shifters (combinational, z3) and all five iterative units
(MUL/DIV + the three FP units) against their standalone `.v`; the register file against its
behavioural `registers_spec.v`; and the **whole core glue** — including the **in-situ ALU**
(`aluRes`, which has no standalone `.v`) — against `RISC5.v` with the 8 submodules black-boxed
and assumed-equivalent on the leaf proofs above. And the **Tier-1 peripherals** (RS232R/T, SPI,
PS2) are proven ≡ their `.v` by the same sequential recipe — the exhaustive upgrade of their
Phase-6a cosim — plus **Tier 2**: the **Mouse** through an open-drain `inout` shim, and **VID**'s
raster + pixel datapath through a multiclock proof that cuts around its **two** deliberate departures
(the CDC and the 2-group prefetch). Those cuts are closed separately: the CDC's **fetch invariant**
(one `req` per `req0`, no loss, no spurious — all clk/pclk phases, all states) by `yosys-smtbmc`
k-induction (`vid_invariant`); the prefetch's **delivery** by decomposition — the look-ahead address
≡ a geometry spec (`vid_addr`, combinational Sec/z3, all `(hcnt,vcnt)`) + that same `vid_invariant`
for timing + a reviewed composition lemma (a weaker tier — the one place a hand argument glues the
mechanized pieces; see "VID prefetch delivery" below). **17 checks**, all proven; every one
mutation-checked. (NB the mutation checks were performed *manually at proof-authoring time* —
`@formal` re-runs only the positive proofs; there is no re-runnable mutation harness. The
specific mutations and their observed failures are recorded per-proof below.)

## Peripheral modules — Tier 1 + Tier 2 done (VID partial by design)

The formal layer extended to the faithful-`.v` **peripherals**. These are already Verilator-cosim'd
against their `.v` (Phase 6a), so formal here is the *exhaustive* upgrade of a check that already
passes — added rigor (rare corners, the bright line), not a new capability. The SoC top
(`RISC5Top`) is **out of scope** — board-specific (our sim `Soc` ≠ `RISC5Top.OStation.v` by design:
DCM/PROM/IOBUF/memory are Phase 7).

**Tier 1 — done (a `sequential` row each, via `run_proof` + `sequential.ys.template`).** Single-clock
FSMs with a direct standalone `.v`, closed by the standard `equiv_induct` recipe; each row carries the `renames` that
pair our lib reg names to the RTL's (the lib keeps its waveform/SoC-namespaced names). Each proof
mutation-checked (a one-line gate bug leaves exactly the affected `$equiv` cells unproven):
- [x] `RS232T` ≡ `RS232T.v` — names already match (`run`/`tick`/`bitcnt`/`shreg`), no renames.
- [x] `RS232R` ≡ `RS232R.v` — `q0→Q0`, `q1→Q1` (the synchronizer FFs); `stat`/`bitcnt` newly named
  in the lib. 30 cells.
- [x] `SPI` ≡ `SPI.v` — `spi_shreg→shreg`. `rdy` is an `output reg`, so it pairs via the output
  *port* even though Hardcaml emits the FF as `rdy_0` (the two-object reg/port split vs the RTL's
  single `output reg`). 78 cells.
- [x] `PS2` ≡ `PS2.v` — `q0→Q0`, `q1→Q1`; the 16×8 `fifo` lowers via the `memory` pass and pairs
  by name (128 of the 160 cells), the same mechanism as the register-file proof.

**Tier 2 — one wrinkle each:**
- [x] `Mouse` ≡ `MousePM.v` (module `MouseP`) — **done** (`run_mouse` + `proofs/mouse.ys.template`,
  `proofs/mouse_shim.v`). `MouseP` has open-drain `inout msclk, msdat`; we split each into a `*_oe` drive +
  the resolved input. Two shims wrap *both* sides into one explicit interface whose external read is
  a **free** input (essential — without it yosys ties the inout read to 0 and the FSM degenerates to
  constants, a vacuous proof) and whose observable is the **resolved line** `oe ? 0 : ext`. The
  tristate is lowered with `tribuf -formal` (converts the inout-port drivers too, which `-logic`
  won't) + `chformal -remove` (drop tribuf's "no two drivers" assertion — illegal for open-drain
  wire-AND) + `setundef -one` (the both-released float = the pad pull-up). 160 cells; mutation-checked
  on state, the `*_oe` drive, *and* the resolved-line read. `count`/`filter` newly named in the lib;
  the flattened FFs are renamed `g.X→X` to pair with the RTL.
- [x] `VID` ≡ `VID60.v` — **done, partial by design** (`run_vid` + `proofs/vid.ys.template`,
  `proofs/vid_stubs.v`). Two clock domains (`pclk` raster + `clk` DMA) ⇒ **multiclock** equiv. Gold prep:
  `VID60.v` makes `pclk` with a Xilinx DCM (a Phase-7 primitive), so we stub + drop the DCM/BUFG and
  `expose -input pclk` to match our gate; `chparam RGBW=6`. **Two** parts of our port *deliberately*
  depart from the RTL, so a whole-VID equiv can't close — we prove **around** both: (1) the
  framebuffer-fetch **CDC** (our toggle pulse-synchroniser vs `VID60.v`'s async-set `req1`), and (2) the
  2-group **prefetch** (our look-ahead `vidadr` + ping-pong banks `buf0`/`buf1` vs the RTL's single
  `vidbuf` / current-group address — the Nexys-4 flicker fix). We **cut** `vidbuf` (the word `pixbuf`
  loads — on our side the ping-pong read mux, *named* `vidbuf` to pair with the RTL register) to a
  shared free input, so `pixbuf`/`RGB` prove bit-exact *given the same word*; and **exclude** BOTH
  departed outputs `req` and `vidadr` via `equiv_remove -gate` (each gold cone then feeds only its
  excluded output, never SAT-solved). Proven: the raster (`hcnt/vcnt/hs/vs/blank` → `hsync/vsync`) + the
  pixel datapath (`pixbuf` → `RGB`) ≡ `VID60.v`, given the same fetched word (mutation-checked on raster
  *and* pixel paths). The two cut parts are closed separately: the CDC by the `vid_invariant` property
  proof (below); the prefetch *delivery* by decomposition (next).

- **VID prefetch delivery** — *formalized by decomposition* (closing the `vidadr` cut above). The equiv
  proves the display is correct *given the right word*; **delivery** is the claim that the 2-group prefetch
  *delivers* that word — the word loaded into `pixbuf` for the visible group at screen position `(v,c)`
  equals `Org+{~v,c}` (what `VID60.v` fetches there). A single end-to-end k-induction of this does **not**
  converge (it is exactly the spanning invariant **D** below), so we prove it as **three machine-checked
  pieces + one composition lemma**:

  1. **Addressing** — `vid_addr`, combinational Sec/z3, *all* `(hcnt,vcnt)`. The look-ahead logic
     `Video.lookahead` ≡ an independent geometry spec: the request that targets the consume of `(v,c)` —
     issued at the previous group's `req0` (display-col `c-1`, or the prior line's col 31 when `c=0`) —
     computes `vidadr = Org+{~v,c}` and write-bank `lsb next_col = c[0]`. (`run_vid_addr`; the *new* check.
     There is no reference `.v` for the look-ahead — `VID60.v`'s address is the *current* group — so it is
     proven against a geometry spec we write, register-file-style; the spec uses a different form
     (5-bit-wrap col, shift/add packing) so the equivalence cross-checks rather than restates. Teeth: drop
     the `~` on `next_vcnt` ⇒ counterexample.)
  2. **Routing** — `vid_addr` write side + a definitional read side. Write-bank `= c[0]` (above);
     read-bank at the consume `= hcnt[5] = c[0]` (definitional: at the `(v,c)` xfer `hcnt[9:5]=c`). Same
     bank.
  3. **Timely, unclobbered arrival** — `vid_invariant` + a ping-pong margin. `vid_invariant` proves each
     `req0` yields exactly one `clk` write pulse `req` — no loss, no duplication, **all phases**. The
     fill→consume window is ≥ one 32-px group (≈12 `clk`; for `c=0`/frame-top, ≥ a full blanking interval),
     comfortably past the 3-FF synchroniser, so the write lands before the consume. Same-bank writes are
     exactly two groups apart (parity alternates) while the consume is one group after its fill, so the next
     write to `buf[c[0]]` is *after* the consume — nothing clobbers the word in the window, including across
     the idle blanking hold (no `req0` fires there at all).

  **Composition lemma (the glue — a reviewed hand argument).** The consume of `(v,c)` reads
  `vidbuf = buf[hcnt[5]] = buf[c[0]]` at its xfer (2). By (1) the request that fills `buf[c[0]]` for this
  group deposited `Org+{~v,c}` (under the echo memory, `mem[Org+{~v,c}]`); by (3) that write happened
  exactly once, before the consume, and survives unclobbered to it. Hence `vidbuf = mem[Org+{~v,c}]` at the
  `(v,c)` xfer — delivery. ∎  Pieces (1)+(2)-write are machine-checked over all `(hcnt,vcnt)`, (2)-read is
  the bit identity, (3)'s phase-sensitive half over all phases; what is **not** mechanized is the remaining
  counter arithmetic in (3) (the ≥1-group window, the 2-group inter-write spacing) and the *threading* of
  one specific `req0` to one specific consume — that is this lemma.

  **Status / honesty.** This is a *weaker* tier than the core's assume-guarantee, whose side-condition (no
  combinational path crosses a submodule boundary) is essentially mechanical; here the glue is a
  counting/correspondence argument. The co-located sim test "vid — prefetch look-ahead: every column
  delivers its own word, across rows" (`lib/video.ml`) cross-validates the *assembled* property at one
  clk/pclk phase — address-echoing memory, all 32 columns over two consecutive rows (so each row's `c=0`
  exercises the cross-line wrap), plus a frame-top-gap test showing the one-group transient self-heals.
  Phase is irrelevant to the pclk-domain addressing (which is why one phase suffices there, and `vid_addr`
  carries the exhaustiveness over `(hcnt,vcnt)`).

  **Why the composition stays prose — i.e. why not one proof (D).** The thread from fill to consume spans
  the idle blanking: for `c=0` the word is fetched at the *previous line's* col 31 (≈383 px ≈ 147 `clk`),
  and the frame's first `c=0` at the *previous frame's* — ≈38 lines. A single inductive proof would have to
  hold the word stable across that span, i.e. carry the invariant "`buf[p]` = mem of the next parity-`p`
  group" — and *that invariant is the monolithic delivery proof* **(D)**. It does not converge tractably: a
  prototype (echo DUT + a `vid_invariant`-style monitor, `yosys-smtbmc -i` k-induction) is *true* on
  inspection — every counterexample is an unreachable inductive-start state (a "valid" bank whose fill is
  outside the window, landing exactly at `vcnt=0,col=0`) — but k-induction fails at the inductive step for
  `k = 96..140` and runs `>6 min` without converging at `k = 256` (`clk2fflogic`'s multiclock granularity
  makes even the within-line `~63 px` fill need `k > 256`, vs `vid_invariant`'s 48). So D is deliberately
  not pursued; the decomposition trades that one deep proof for the three shallow checks + this lemma.
- [x] `vid_invariant` — the fetch CDC's protocol, **formally** (`run_vid_invariant` +
  `proofs/vid_invariant.ys.template`, `proofs/vid_invariant.v`). The CDC is *not* a cycle-equivalence (our toggle
  synchroniser vs the async-set `req1`), so equiv can't touch it — but the *protocol* is provable:
  **one `req` per `req0`, no loss, no duplication**. `video.ml`'s `pulse_sync` is extracted as a
  reusable primitive; the harness isolates it (`req0` an input), wraps it with a `req0` generator +
  a clock-fairness assumption + a balance monitor, and discharges no-loss + no-spurious by
  `yosys-smtbmc -i`/z3 **k-induction** (k=48) over **all fair clk/pclk phase interleavings** — the
  CDC-robustness the single-phase Cyclesim test can't reach. **Unbounded** (all reachable states): no
  hand-crafted inductive invariant was needed — k just has to span a fetch cycle (threshold ≈ 38) so
  the k-step history forces a reachable-consistent state. Mutation-checked (drop the toggle → caught).

  *This proof's "correct failure" at the CDC was not academic: the `pclk`-domain `caught` one-shot it
  flagged turned out to be a real metastability bug on silicon (horizontal flicker on the Nexys 4). The
  fix — a textbook toggle pulse-synchroniser — is what `video.ml` now ships, and what this proves around.*

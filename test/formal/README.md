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
Risc5_core (gate) ───┘     → equiv_simple + equiv_induct → all $equiv proven
  via create_with_units (Core_blackbox.units = Instantiation stubs)
```

The whole core proven against `RISC5.v` — **except** its 8 submodules, which are black-boxed
and *assumed* equivalent (sound: each is proven separately above — 7 vs their `.v`, the
register file vs its contract). What's left, and what this proves, is the **glue**: decode,
the **inline ALU (`aluRes` — no standalone `.v`, finally proven in-situ)**, the control unit
(`pcmux`/`cond`), the flag logic, and the 13 state registers (`PC`/`IR`/flags/`H`/`stallL1`/
interrupt state).

The seam is `Risc5_core.create_with_units`: `Core_blackbox` passes `Instantiation` stubs whose
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
  `Risc5_core.create_with_units`), `proofs/core_stubs.v` (the stubs), and `run_core` +
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

The datapath + core layer is closed: both shifters (combinational, z3) and all five iterative units
(MUL/DIV + the three FP units) against their standalone `.v`; the register file against its
behavioural `registers_spec.v`; and the **whole core glue** — including the **in-situ ALU**
(`aluRes`, which has no standalone `.v`) — against `RISC5.v` with the 8 submodules black-boxed
and assumed-equivalent on the leaf proofs above. And the **Tier-1 peripherals** (RS232R/T, SPI,
PS2) are proven ≡ their `.v` by the same sequential recipe — the exhaustive upgrade of their
Phase-6a cosim — plus **Tier 2**: the **Mouse** through an open-drain `inout` shim, and **VID**'s
raster + pixel datapath through a multiclock proof that cuts around its (deliberate) CDC departure,
with that departure's **fetch invariant** (one `req` per `req0`, no loss, no spurious — all clk/pclk
phases, all states) closed separately by `yosys-smtbmc` k-induction. **16 checks**, all proven;
every one mutation-checked.

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
  `expose -input pclk` to match our gate; `chparam RGBW=6`. The framebuffer-fetch CDC *deliberately*
  departs from the RTL (our toggle pulse-synchroniser vs `VID60.v`'s async-set `req1`), so a whole-VID
  equiv can't close there — we prove **around** it: **cut** `vidbuf` (the fetched word) to a shared
  free input (so `pixbuf`/`RGB` prove bit-exact *given the same word*) and **exclude** the `req`
  output via `equiv_remove -gate` (the gold's async-set `$adff` then feeds only the excluded `req`, so
  it's never SAT-solved). Proven: the raster (`hcnt/vcnt/hs/vs/blank` → `vidadr/hsync/vsync`) + the
  pixel datapath ≡ `VID60.v` (79 cells; mutation-checked on raster *and* pixel paths). The fetch CDC
  itself — the cut part — is closed by a **separate property proof** (`vid_invariant`, below).
- [x] `vid_invariant` — the fetch CDC's protocol, **formally** (`run_vid_invariant` +
  `proofs/vid_invariant.ys.template`, `proofs/vid_invariant.v`). The CDC is *not* a cycle-equivalence (our toggle
  synchroniser vs the async-set `req1`), so equiv can't touch it — but the *protocol* is provable:
  **one `req` per `req0`, no loss, no duplication**. `vid.ml`'s `pulse_sync` is extracted as a
  reusable primitive; the harness isolates it (`req0` an input), wraps it with a `req0` generator +
  a clock-fairness assumption + a balance monitor, and discharges no-loss + no-spurious by
  `yosys-smtbmc -i`/z3 **k-induction** (k=48) over **all fair clk/pclk phase interleavings** — the
  CDC-robustness the single-phase Cyclesim test can't reach. **Unbounded** (all reachable states): no
  hand-crafted inductive invariant was needed — k just has to span a fetch cycle (threshold ≈ 38) so
  the k-step history forces a reachable-consistent state. Mutation-checked (drop the toggle → caught).

  *This proof's "correct failure" at the CDC was not academic: the `pclk`-domain `caught` one-shot it
  flagged turned out to be a real metastability bug on silicon (horizontal flicker on the Nexys 4). The
  fix — a textbook toggle pulse-synchroniser — is what `vid.ml` now ships, and what this proves around.*

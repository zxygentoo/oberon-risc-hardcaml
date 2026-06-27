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

## Running

Opt-in (like the cosim) — needs **yosys** on `PATH` (both modes) and **z3** (combinational
mode), plus the `hardcaml_verify` / `hardcaml_of_verilog` libraries (AGENT.md §9):

```
dune build @formal            # prove every unit
bash test/formal/run.sh       # same, standalone
```

The reference Verilog is **not** vendored; `run.sh` fetches + checksum-verifies it on demand
via [`../cosim/fetch-rtl.sh`](../cosim/rtl-sources.txt) (shared provenance with the cosim).

## Adding a unit

In `test_formal.ml`:
- **Combinational** (standalone `.v`, no state): add a row to `combinational` — a thunk building
  the circuit via `Circuit.With_interface (Unit.I) (Unit.O)` (ports match the `.v`), plus the
  reference `.v` + top-module name.
- **Sequential**: name the unit's registers after the RTL in `lib/`, then add a row to
  `sequential` — a thunk building the circuit with `Circuit.create_exn` and ports named to match
  the `.v` (and a module name *distinct* from the reference, since yosys reads both).
- **Behavioural spec** (a unit whose RTL is a synthesis idiom, not behaviour — so far only the
  register file): add a checked-in `*_spec.v` here, a thunk, and a row to `behavioral` (reference
  dir is `spec_dir = test/formal`, not the fetched `_po/`). Same `equiv_induct` path.

Every datapath unit is now proven: both shifters (combinational, z3) and all five iterative units
(MUL/DIV + the three FP units) against their standalone `.v`, plus the register file against its
behavioural `registers_spec.v`. The ALU has no standalone `.v` (inline in `RISC5.v`) and is deferred
to the in-situ core proof, alongside the full `RISC5.v` core — which can now black-box the register
file on this proven behavioural contract.

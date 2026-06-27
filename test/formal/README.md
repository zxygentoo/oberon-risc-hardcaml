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

The ALU has no standalone `.v` (inline in `RISC5.v`) and is deferred to the in-situ core proof;
the FP units follow the Multiplier's sequential pattern (the Divider already does — it names its
`S`/`RQ` to match `Divider.v`).

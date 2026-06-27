# `test/formal` — logic-equivalence proofs vs the reference Verilog

The **Formal** layer of the verification pyramid (AGENT.md §6). Where [`test/cosim`](../cosim)
*simulates* a unit against its reference `.v` and compares samples (Verilator), this *proves*
the two compute the identical function — **exhaustively, over every input**, via SAT.

```
ours: Risc5.Left_shifter (log_shift, radix-2) ─┐
                                               ├─ Sec.create → CNF → z3 → UNSAT = equivalent
LeftShifter.v (Wirth, radix-4 mux tree) ───────┘
```

- **Import:** `hardcaml_of_verilog` lowers the reference `.v` to a `Hardcaml.Circuit.t` (it
  shells out to **yosys**). We drive yosys ourselves with `write_json -compat-int` —
  yosys 0.65 emits cell parameters as binary strings by default, which the importer's techlib
  rejects; the flag emits them as JSON numbers (see `formal_equiv.ml`). No fork needed.
- **Prove:** `hardcaml_verify`'s `Sec` builds a miter of the two circuits and SAT-checks it
  with **z3**. `Unsat` ⇒ equivalent; `Sat` ⇒ a counterexample input exists.

`Sec` is **combinational** ("stateful logic must be the same between the two circuits"), so this
is a *complete* proof for the datapath blocks (shifters, ALU logic/adder) and is deferred for
the stateful units (MUL/DIV/FP, the core), which need register-mapping / k-induction.

## Running

Opt-in (like the cosim) — needs **yosys** and **z3** on `PATH`, plus the `hardcaml_verify`
and `hardcaml_of_verilog` libraries installed (AGENT.md §9):

```
dune build @formal            # prove every unit
bash test/formal/run.sh       # same, standalone
```

The reference Verilog is **not** vendored; `run.sh` fetches + checksum-verifies it on demand
via [`../cosim/fetch-rtl.sh`](../cosim/rtl-sources.txt) (shared provenance with the cosim).

## Adding a unit

Add a row to `cases` in `test_formal.ml`: a label, a thunk building the Hardcaml circuit
(`Circuit.With_interface (Unit.I) (Unit.O)`, so ports match the Verilog's), and the reference
`.v` + top-module name. Combinational units only, for now.

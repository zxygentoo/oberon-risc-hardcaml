# test/cosim — RTL-fidelity co-simulation (opt-in)

Confirms a Hardcaml design is **bit-exact to Wirth's original Verilog** by driving the
reference RTL through **Verilator** and comparing, cycle output by cycle output, against the
Hardcaml port. This is the simulation-based preview of the Phase-8 formal-equivalence proof
(`hardcaml_verify`), and the project's *fidelity* oracle — distinct from the OCaml emulator,
which is the *behavioural / system-state* oracle (see AGENT.md §6).

It is **not** part of `dune runtest`. It needs:

- `verilator` on `PATH` (it is not in the ox/opam toolchain), and
- `po/verilog/src/*.v` present (the original RTL is git-ignored).

## Run

```sh
bash test/cosim/run.sh
```

Builds the OCaml dumper, dumps the Hardcaml `Fp_adder`'s output over the frozen `fp_vectors`
`A`-stimuli **+ 20 000 random fuzz** cases, verilates `po/verilog/src/FPAdder.v`, and asserts
`RTL z == port z` for every stimulus (expect `0 mismatch`). Build artifacts go to
`$CLAUDE_JOB_DIR/tmp` (scratch); nothing is written into the tree.

## How it works

| file | role |
|---|---|
| `dump_fp_adder.ml` | Hardcaml `Fp_adder` → `"x y u v z"` lines — the stimulus source |
| `fp_adder.cpp` | Verilator harness: replay each line through `FPAdder.v`, compare `z` |
| `run.sh` | glue: build → dump → verilate → cross-check |

The OCaml dumper builds under `dune build @check` (Verilator-free), so it can't silently rot
even though the cross-check itself only runs via `run.sh`.

## Adding another unit (MUL / DIV / FPMul / FPDiv / core)

Copy the pair — `dump_<unit>.ml` (drive the Hardcaml unit, dump its I/O) and `<unit>.cpp`
(replay through the unit's `.v`) — add the executable to `dune`, and point a `run.sh`
invocation at the unit's `.v` + top-module name. The drive protocol (`run` → drain on
`stall` → read) is shared by all the stall-based sequential units, so most of
`dump_fp_adder.ml` / `fp_adder.cpp` is reusable.

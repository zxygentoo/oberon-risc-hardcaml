# test/cosim — RTL-fidelity co-simulation (opt-in)

Confirms a Hardcaml design is **bit-exact to Wirth's original Verilog** — in both result
*and* timing — by driving the reference RTL through **Verilator** and comparing each
stimulus's output `z` and its stall length against the Hardcaml port. This is the
simulation-based preview of the Phase-8 formal-equivalence proof
(`hardcaml_verify`), and the project's *fidelity* oracle — distinct from the OCaml emulator,
which is the *behavioural / system-state* oracle (see AGENT.md §6).

It is **not** part of `dune runtest`. It needs only:

- `verilator` on `PATH` (it is not in the ox/opam toolchain).

The reference Verilog is **not vendored** (its licensing is unclear and we prefer not to
redistribute it). `run.sh` fetches it on demand into `_po/` and checksum-verifies it against
`rtl-sources.txt` (see *Reference RTL* below), so a fresh clone with `verilator` just works.

## Run

```sh
bash test/cosim/run.sh                  # all FP units
bash test/cosim/run.sh fp_divider       # just one (fp_adder | fp_multiplier | fp_divider)
```

Ensures the reference RTL is present (fetching it on first run), builds the OCaml dumper, then
for each unit dumps the Hardcaml port's output over the frozen `fp_vectors` stimuli for that unit
(`A`/`M`/`D` lines) **+ 20 000 random fuzz** cases, verilates the reference `.v`, and asserts
`RTL z == port z` **and** `RTL stall-length == port stall-length` for every stimulus (expect
`0 value-mismatch, 0 cycle-mismatch`). Scratch (the downloaded zip,
Verilator's `obj_dir`) goes to `$CLAUDE_JOB_DIR/oberon-cosim`; the only tree write is the
fetched `_po/verilog/src/*.v` (git-ignored).

## Reference RTL (fetch-on-demand + checksum pin)

`run.sh`'s `ensure_rtl` populates `_po/verilog/src/` once, on demand: if the pinned `.v` are
already cached and match, it does nothing; otherwise it downloads `OStationVerilog.zip` from the
upstream URL, verifies the archive SHA-256, extracts `src/*.v`, and verifies each file against
`rtl-sources.txt` before trusting it. The pins are **fidelity-critical**: a mismatch means
upstream drifted from the exact revision the port (and AGENT.md §8's line-number citations) was
verified against, so the co-sim refuses rather than compare against unknown RTL. Updating to a
newer upstream revision is a deliberate edit of `rtl-sources.txt`. Offline fallback: download the
zip yourself and unzip its `src/*.v` into `_po/verilog/src/`.

## How it works

| file | role |
|---|---|
| `dump_fp.ml` | one dumper for all FP units: drive `Risc5.Fp_<unit>` (chosen by the unit-name argument) over the stimuli, dump `"x y [u v] z cycles"` lines (`cycles` = the port's stall length) — the stimulus source |
| `<unit>.cpp` | Verilator harness, one per unit: replay each line through `<Unit>.v`, compare `z` and the RTL's own stall length against the port's |
| `run.sh` | glue: build → dump → verilate → cross-check, per unit |

The OCaml dumper builds under `dune build @check` (Verilator-free), so it can't silently rot
even though the cross-check itself only runs via `run.sh`.

## Adding another unit (the CPU core, peripherals)

The dumper is shared, so adding a stall-based unit is three small steps:

1. a `*_driver ()` in `dump_fp.ml` (build its sim, set its inputs, return `drive`'s
   `(z, cycles)`) plus one arm in the unit-name `match` — the `run` → drain on `stall` → read
   protocol (and its stall-cycle count) is already shared by `drive`;
2. a `<unit>.cpp` Verilator harness (replay each dumped line through the unit's `.v`, compare
   `z` and the RTL's stall length against the port's `cycles`);
3. a `run_one` arm in `run.sh` pointing at the unit's `.v` + top-module name.

The adder carries `u`/`v` modifiers and a 6-field vector line (`A`); the mul/div units don't
(`M`/`D`, 4-field). The `driver` record's `has_uv`/`tag` fields capture exactly that difference.

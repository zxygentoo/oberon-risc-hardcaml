#!/usr/bin/env bash
# Formal logic-equivalence (AGENT.md §6, the "Formal" layer): prove our Hardcaml
# combinational units compute the identical function as their reference Verilog, via
# hardcaml_of_verilog (yosys import) + hardcaml_verify (Sec — a SAT equivalence check, z3).
# The exhaustive counterpart to the Verilator co-sim (test/cosim), which samples the same
# comparison; here z3 proves it over every input.
#
# OPT-IN — not part of `dune runtest`. Needs `yosys` and `z3` on PATH (outside the ox
# toolchain), like the cosim needs `verilator`. The reference Verilog is fetched +
# checksum-verified on demand by ../cosim/fetch-rtl.sh (shared provenance, see its README).
#
#   usage:  bash test/formal/run.sh
#   or:     dune build @formal
set -euo pipefail
cd "$(git rev-parse --show-toplevel)" # repo root (works standalone and from the @formal action)
eval "$(opam env --switch 5.2.0+ox --set-switch)"

for tool in yosys z3; do
  command -v "$tool" >/dev/null \
    || { echo "[formal] needs '$tool' on PATH — see test/formal/README.md" >&2; exit 2; }
done

bash test/cosim/fetch-rtl.sh # populate + checksum-verify _po/verilog/src/*.v (shared with cosim)

# Build the exe only when absent — `dune build @formal` declares it a dep (pre-built), so this
# never nests a dune invocation inside the dune action.
exe=_build/default/test/formal/test_formal.exe
[ -x "$exe" ] || dune build test/formal/test_formal.exe
exec "$exe"

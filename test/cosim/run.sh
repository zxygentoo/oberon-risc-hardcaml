#!/usr/bin/env bash
# RTL-fidelity co-sim: assert the Hardcaml Fp_adder is bit-exact to po/verilog/src/FPAdder.v
# over the frozen fp_vectors A-stimuli + random fuzz, via Verilator.
#
# OPT-IN — not part of `dune runtest`. Needs `verilator` on PATH (outside the ox toolchain)
# and po/ present (the original RTL is git-ignored). See test/cosim/README.md.
set -euo pipefail
cd "$(dirname "$0")/../.." # repo root
eval "$(opam env --switch 5.2.0+ox --set-switch)"

vec=vendor/oberon-risc-emu-ocaml/test/data/fp_vectors.txt
rtl=po/verilog/src/FPAdder.v
work="${CLAUDE_JOB_DIR:-/tmp}/cosim-fp_adder"
mkdir -p "$work"

command -v verilator >/dev/null || {
  echo "error: verilator not on PATH" >&2
  exit 2
}
[ -f "$rtl" ] || {
  echo "error: $rtl missing (po/ is git-ignored — fetch the original RTL first)" >&2
  exit 2
}

echo "[1/3] dumping Hardcaml Fp_adder outputs over the stimulus set ..."
dune build test/cosim/dump_fp_adder.exe
_build/default/test/cosim/dump_fp_adder.exe "$vec" >"$work/port_z.txt"

echo "[2/3] verilating $rtl + harness ..."
verilator --cc --exe --build -Wno-fatal --top-module FPAdder \
  --Mdir "$work/obj_dir" \
  "$(pwd)/$rtl" "$(pwd)/test/cosim/fp_adder.cpp" -o cosim 2>&1 | tail -2

echo "[3/3] cross-checking RTL vs port ..."
"$work/obj_dir/cosim" "$work/port_z.txt"

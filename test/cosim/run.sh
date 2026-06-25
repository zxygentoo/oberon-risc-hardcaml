#!/usr/bin/env bash
# RTL-fidelity co-sim: assert a Hardcaml unit is bit-exact to its reference Verilog over the
# frozen fp_vectors stimuli + random fuzz, in both result and timing, via Verilator.
#
# OPT-IN — not part of `dune runtest`. Needs `verilator` on PATH (outside the ox toolchain). The
# reference Verilog is fetched + checksum-verified on demand by fetch-rtl.sh (see README.md).
#
#   usage:  bash test/cosim/run.sh [fp_adder | fp_multiplier | fp_divider | spi | rs232t | all]  (default: all)
#   or:     dune build @cosim                                            (runs every unit)
set -euo pipefail
cd "$(git rev-parse --show-toplevel)" # repo root (works standalone and from the @cosim action)
eval "$(opam env --switch 5.2.0+ox --set-switch)"

vec=vendor/oberon-risc-emu-ocaml/test/data/fp_vectors.txt
rtl_dir=_po/verilog/src
work_root="${CLAUDE_JOB_DIR:-/tmp}/oberon-cosim"

# The co-sim units, one row each — collapses the old per-unit functions to data:
#   name           reference .v     top-module     harness .cpp        dumper
# Stall-based FP units share dump_fp (selected by name) + fp_cosim.h; the SPI master is a serial
# handshake unit (not stall-based) with its own dump_spi + spi.cpp — captured as just the dumper
# column. Adding a unit (CPU core, peripherals) is a new row + its .cpp (+ a dump_fp arm or a new
# dumper); see README.md "Adding another unit".
units_table=$(
  cat <<'TBL'
fp_adder        FPAdder.v        FPAdder        fp_adder.cpp        dump_fp
fp_multiplier   FPMultiplier.v   FPMultiplier   fp_multiplier.cpp   dump_fp
fp_divider      FPDivider.v      FPDivider      fp_divider.cpp      dump_fp
spi             SPI.v            SPI            spi.cpp             dump_spi
rs232t          RS232T.v         RS232T         rs232t.cpp          dump_rs232t
TBL
)

unit_names() { awk 'NF {print $1}' <<<"$units_table"; }

# Build the dumper only when it isn't already present — so `dune build @cosim` (which declares the
# exes as deps, pre-building them) never triggers a nested `dune build` inside the dune action.
ensure_dumper() {
  local exe="_build/default/test/cosim/$1.exe"
  [ -x "$exe" ] && return 0
  dune build "test/cosim/$1.exe"
}

# cosim_unit <name> <Unit.v> <TopModule> <harness.cpp> <dumper>: dump the Hardcaml port's outputs
# over the stimulus set, verilate the reference .v + harness, cross-check RTL vs port (value AND
# timing). The harness .cpp self-asserts (exits nonzero on any mismatch).
cosim_unit() {
  local name=$1 rtl_file=$2 top=$3 cpp=$4 dumper=$5
  local rtl="$rtl_dir/$rtl_file" work="$work_root/$name"
  mkdir -p "$work"
  echo "=== $name ==="
  echo "[1/3] dumping Hardcaml $name outputs over the stimulus set ..."
  ensure_dumper "$dumper"
  # dump_fp takes <unit> <fp_vectors>; dump_spi records its own per-cycle stimulus (no args).
  if [ "$dumper" = dump_fp ]; then
    "_build/default/test/cosim/$dumper.exe" "$name" "$vec" >"$work/port.txt"
  else
    "_build/default/test/cosim/$dumper.exe" >"$work/port.txt"
  fi
  echo "[2/3] verilating $rtl + harness ..."
  verilator --cc --exe --build -Wno-fatal --top-module "$top" \
    --Mdir "$work/obj_dir" \
    "$(pwd)/$rtl" "$(pwd)/test/cosim/$cpp" -o cosim 2>&1 | tail -2
  echo "[3/3] cross-checking RTL vs port ..."
  "$work/obj_dir/cosim" "$work/port.txt"
}

run_one() {
  local want=$1 name rtl top cpp dumper
  while read -r name rtl top cpp dumper; do
    [ "$name" = "$want" ] && {
      cosim_unit "$name" "$rtl" "$top" "$cpp" "$dumper"
      return 0
    }
  done <<<"$units_table"
  echo "unknown unit: $want (expected $(unit_names | tr '\n' ' ')| all)" >&2
  exit 2
}

command -v verilator >/dev/null || {
  echo "error: verilator not on PATH" >&2
  exit 2
}

bash test/cosim/fetch-rtl.sh

unit="${1:-all}"
if [ "$unit" = all ]; then
  while read -r name rtl top cpp dumper; do
    [ -n "$name" ] && cosim_unit "$name" "$rtl" "$top" "$cpp" "$dumper"
  done <<<"$units_table"
else
  run_one "$unit"
fi

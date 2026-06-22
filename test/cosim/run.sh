#!/usr/bin/env bash
# RTL-fidelity co-sim: assert a Hardcaml FP unit is bit-exact to its reference Verilog over the
# frozen fp_vectors stimuli + random fuzz, via Verilator.
#
# OPT-IN — not part of `dune runtest`. Needs `verilator` on PATH (outside the ox toolchain).
# The reference Verilog is NOT vendored (licensing); it is fetched on demand into _po/ and
# checksum-verified against test/cosim/rtl-sources.txt — so a fresh clone with verilator just
# works. See test/cosim/README.md.
#
#   usage:  bash test/cosim/run.sh [fp_adder | fp_multiplier | fp_divider | all]  (default: all)
set -euo pipefail
cd "$(dirname "$0")/../.." # repo root
eval "$(opam env --switch 5.2.0+ox --set-switch)"

vec=vendor/oberon-risc-emu-ocaml/test/data/fp_vectors.txt
manifest=test/cosim/rtl-sources.txt
rtl_dir=_po/verilog/src
work_root="${CLAUDE_JOB_DIR:-/tmp}/oberon-cosim"
mkdir -p "$work_root"

command -v verilator >/dev/null || {
  echo "error: verilator not on PATH" >&2
  exit 2
}

# the "<sha256>  <path>" pin lines from the manifest (comments + blanks stripped); they double
# as the `sha256sum -c` gate on the cached/fetched RTL.
pins() { grep -vE '^[[:space:]]*(#|$)' "$manifest"; }

# Populate + verify $rtl_dir once, on demand. The reference Verilog is fetched from the pinned
# upstream archive and checksum-verified; a mismatch means upstream drifted from the revision the
# port (and AGENT.md §8) was verified against — we refuse rather than co-sim against unknown RTL.
ensure_rtl() {
  # cache present and matching → done. 2>/dev/null hushes sha256sum's "No such file" stderr on
  # a fresh clone (the files don't exist yet); --status alone doesn't suppress open errors.
  if pins | sha256sum -c --status - 2>/dev/null; then return 0; fi
  local url zip_sha zip
  url=$(awk '$1=="#" && $2=="url" {print $3}' "$manifest")
  zip_sha=$(awk '$1=="#" && $2=="zip256" {print $3}' "$manifest")
  zip="$work_root/OStationVerilog.zip"
  echo "[rtl] fetching reference Verilog: $url"
  curl -fsSL -o "$zip" "$url" || {
    echo "[rtl] fetch failed (offline?). Manual fallback: download $url and unzip its" >&2
    echo "      src/*.v into $rtl_dir/, then re-run." >&2
    exit 2
  }
  echo "$zip_sha  $zip" | sha256sum -c --status - || {
    echo "[rtl] archive checksum mismatch — upstream changed; refusing (see $manifest)" >&2
    exit 2
  }
  mkdir -p "$rtl_dir"
  unzip -o -q "$zip" 'src/*.v' -d "$work_root"
  cp "$work_root"/src/*.v "$rtl_dir"/
  pins | sha256sum -c --status - || {
    echo "[rtl] extracted .v checksum mismatch — refusing (see $manifest)" >&2
    exit 2
  }
  echo "[rtl] fetched + verified into $rtl_dir/"
}

# cosim_unit <name> <Unit.v> <TopModule> <harness.cpp> — the dumper is the shared dump_fp.exe
# selected by <name>; the .v lives in $rtl_dir, the .cpp harness is per-unit.
cosim_unit() {
  local name="$1" rtl="$rtl_dir/$2" top="$3" cpp="$4"
  local work="$work_root/$name"
  mkdir -p "$work"
  echo "=== $name ==="
  echo "[1/3] dumping Hardcaml $name outputs over the stimulus set ..."
  dune build test/cosim/dump_fp.exe
  _build/default/test/cosim/dump_fp.exe "$name" "$vec" >"$work/port_z.txt"
  echo "[2/3] verilating $rtl + harness ..."
  verilator --cc --exe --build -Wno-fatal --top-module "$top" \
    --Mdir "$work/obj_dir" \
    "$(pwd)/$rtl" "$(pwd)/$cpp" -o cosim 2>&1 | tail -2
  echo "[3/3] cross-checking RTL vs port ..."
  "$work/obj_dir/cosim" "$work/port_z.txt"
}

run_one() {
  case "$1" in
    fp_adder)
      cosim_unit fp_adder FPAdder.v FPAdder test/cosim/fp_adder.cpp
      ;;
    fp_multiplier)
      cosim_unit fp_multiplier FPMultiplier.v FPMultiplier test/cosim/fp_multiplier.cpp
      ;;
    fp_divider)
      cosim_unit fp_divider FPDivider.v FPDivider test/cosim/fp_divider.cpp
      ;;
    *)
      echo "unknown unit: $1 (expected fp_adder | fp_multiplier | fp_divider | all)" >&2
      exit 2
      ;;
  esac
}

ensure_rtl
unit="${1:-all}"
if [ "$unit" = all ]; then
  for u in fp_adder fp_multiplier fp_divider; do run_one "$u"; done
else
  run_one "$unit"
fi

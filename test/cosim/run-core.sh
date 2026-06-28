#!/usr/bin/env bash
# Boot-stream RTL co-sim for the CPU core (AGENT.md §6 layer 3, extended to the whole core —
# its only cycle-level RTL fidelity check before the Phase-8 proof). Capture the core's
# per-cycle I/O over the real Oberon boot, replay it through the reference RISC5.v under
# Verilator, and report the first cycle our port's outputs diverge from the spec.
#
# OPT-IN and heavy: needs verilator + the disk image + the ox toolchain (for the ~25M-cycle
# capture, ~90 s, ~400 MiB trace). The trace is cached; re-running only re-verilates + replays
# (~15 s), so iterate on risc5.cpp cheaply. Env: CAPTURE=1 forces a recapture; SKIP overrides
# the leading compared-skip (default 2 — the reset transient; see risc5.cpp); CORE_TRACE
# overrides the trace path; DISK_IMG / CAP
# are read by the capture (see test/dump_core_trace.ml).
#
#   usage:  bash test/cosim/run-core.sh    (or: dune build @core_cosim)
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

command -v verilator >/dev/null || {
  echo "error: verilator not on PATH" >&2
  exit 2
}

rtl_dir=test/_po/verilog/src
work="test/_work/cosim/core"
mkdir -p "$work"
trace="${CORE_TRACE:-$work/core_boot.trace}"
capture_exe=_build/default/test/dump_core_trace.exe

# the reference RTL (RISC5.v + submodules) — fetched + checksum-verified on demand
bash test/fetch-rtl.sh

# 1. capture the core's boot I/O (skip if a trace is already present and CAPTURE != 1). Only
#    build the capture exe if it isn't already present — so the @core_cosim alias (which
#    pre-builds it as a dep) never nests a `dune build` inside the dune action.
if [ "${CAPTURE:-}" = 1 ] || [ ! -s "$trace" ]; then
  echo "[1/3] capturing core I/O over the boot -> $trace (~90 s) ..."
  if [ ! -x "$capture_exe" ]; then
    eval "$(opam env --switch 5.2.0+ox --set-switch)"
    dune build test/dump_core_trace.exe
  fi
  CORE_TRACE="$trace" "$capture_exe"
else
  echo "[1/3] reusing trace $trace ($(stat -c%s "$trace") bytes); CAPTURE=1 to recapture"
fi

# 2. verilate RISC5.v + its submodules + the RAM16X1D stub (Registers.v infers RAM16X1D, which
#    Verilator does not know — ram16x1d.v supplies its behaviour, like vid_cosim.v's DCM stub).
echo "[2/3] verilating RISC5.v + submodules ..."
vlog="$work/verilate.log"
vargs=(
  --cc --exe --build -Wno-fatal --top-module RISC5 --Mdir "$work/obj_dir"
  "$(pwd)/$rtl_dir/RISC5.v"
  "$(pwd)/$rtl_dir/Registers.v"
  "$(pwd)/$rtl_dir/Multiplier.v"
  "$(pwd)/$rtl_dir/Divider.v"
  "$(pwd)/$rtl_dir/LeftShifter.v"
  "$(pwd)/$rtl_dir/RightShifter.v"
  "$(pwd)/$rtl_dir/FPAdder.v"
  "$(pwd)/$rtl_dir/FPMultiplier.v"
  "$(pwd)/$rtl_dir/FPDivider.v"
  "$(pwd)/test/cosim/ram16x1d.v"
  "$(pwd)/test/cosim/risc5.cpp" -o cosim)
# Self-healing build: on any failure, nuke obj_dir and retry once clean (recovers from a
# stale/partial obj_dir or an intermittent verilator flake); a second failure is real, so show the
# full log rather than masking it behind `| tail`.
if ! verilator "${vargs[@]}" >"$vlog" 2>&1; then
  echo "    verilate failed — cleaning obj_dir and retrying once ..."
  rm -rf "$work/obj_dir"
  if ! verilator "${vargs[@]}" >"$vlog" 2>&1; then
    echo "ERROR: verilator failed:" >&2
    cat "$vlog" >&2
    exit 1
  fi
fi
tail -3 "$vlog"

# 3. replay the captured trace through the RTL and report the first divergence
echo "[3/3] replaying the boot trace through RISC5.v ..."
"$work/obj_dir/cosim" "$trace" "${SKIP:-2}"

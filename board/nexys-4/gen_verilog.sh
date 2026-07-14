#!/usr/bin/env bash
# Regenerate board/_generated/nexys-4/soc_board.v from the Hardcaml design (boot ROM baked
# in). Run from anywhere; resolves the repo root from this script's location.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # board/nexys-4
root="$(cd "$here/../.." && pwd)"                       # repo root
gen="$root/board/_generated/nexys-4"

mkdir -p "$gen"
cd "$root"
dune build board/nexys-4/emit_verilog.exe
dune exec board/nexys-4/emit_verilog.exe > "$gen/soc_board.v"
echo "wrote $gen/soc_board.v ($(wc -l < "$gen/soc_board.v") lines)"

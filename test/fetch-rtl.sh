#!/usr/bin/env bash
# Populate + verify test/_po/verilog/src/*.v for the Verilator co-sim, on demand.
#
# The reference Verilog is NOT vendored (licensing); it is fetched from the pinned upstream
# archive and checksum-verified against test/rtl-sources.txt — so a fresh clone with
# verilator just works while we ship only the provenance pins, never the copyrighted RTL.
#
# A checksum mismatch means upstream drifted from the exact revision the port (and AGENT.md
# §8's RTL line-number citations) was verified against, so we refuse rather than co-sim against
# unknown RTL. Updating to a newer upstream revision is a deliberate edit of rtl-sources.txt.
#
# Standalone or called by run.sh; toolchain-free (curl/unzip/sha256sum/awk/grep only, no opam).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

manifest=test/rtl-sources.txt
rtl_dir=test/_po/verilog/src
# Scratch root: in-repo + self-contained (git-ignored test/_work). The downloaded zip +
# extraction staging live here.
work_root="test/_work/cosim"
mkdir -p "$work_root"

# the "<sha256>  <path>" pin lines from the manifest (comments + blanks stripped); they double
# as the `sha256sum -c` gate on the cached/fetched RTL.
pins() { grep -vE '^[[:space:]]*(#|$)' "$manifest"; }

# cache present and matching → done. 2>/dev/null hushes sha256sum's "No such file" stderr on a
# fresh clone (the files don't exist yet); --status alone doesn't suppress open errors.
if pins | sha256sum -c --status - 2>/dev/null; then
  exit 0
fi

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

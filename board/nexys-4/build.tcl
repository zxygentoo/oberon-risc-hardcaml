# Vivado non-project batch build for the Oberon RISC5 Nexys 4 board top.
# Usage (from anywhere):   vivado -mode batch -source board/nexys-4/build.tcl
# Reads board/_generated/nexys-4/soc_board.v (run gen_verilog.sh first) + the hand-written
# nexys4_top.v / nexys4.xdc; outputs to board/_build/nexys-4/ : oberon.bit + reports.

set here  [file normalize [file dirname [info script]]]   ;# board/nexys-4
set gen   [file normalize $here/../_generated/nexys-4]
set build [file normalize $here/../_build/nexys-4]
set part  xc7a100tcsg324-1
set top   nexys4_top
file mkdir $build
# Remove the previous bitstream up front: the timing gate below refuses to write a new
# one on violation, and program.tcl/flash.tcl must never pick up a stale .bit believing
# it's fresh. (The .bit is regenerable in ~2 min; staleness is the worse failure.)
file delete -force $build/oberon.bit

# ── Read sources ────────────────────────────────────────────────────────────────────
read_verilog $gen/soc_board.v
read_verilog $here/nexys4_top.v
read_xdc     $here/nexys4.xdc

# ── Synthesis ───────────────────────────────────────────────────────────────────────
synth_design -top $top -part $part
write_checkpoint -force $build/post_synth.dcp
report_utilization -file $build/util_synth.rpt

# ── Implementation ──────────────────────────────────────────────────────────────────
opt_design
# Explore-class directives (Phase-10d): the default effort left the RamUBn output missing
# its 6.7 ns PSRAM I/O budget by 0.163 ns — pure placement (3.3 ns of route to the pad,
# the byte-enable cone itself is unchanged); Explore recovers it (WNS +0.130). If this
# margin ever flakes again, the structural fix is registering the byte-enable pins (or
# re-splitting the 6.7/6.6 out/in budget against the measured input-path use), not more
# placer effort.
place_design -directive Explore
phys_opt_design -directive AggressiveExplore
route_design -directive Explore

# Post-route recovery loop (feat/more-cache): the 16 KiB icache (4096-line LUTRAM, 4x the
# shipped 1024) lengthens the combinational hit path — the 60 MHz critical cone — so the
# Explore route lands just short (measured -0.017 ns / 2 endpoints, placement noise on the
# deeper distributed-RAM output mux, not a design gap). Iterated post-route phys_opt closes
# it (same lever the 75 MHz spike used for its own near-miss). Bounded at 8 passes; a design
# that still misses after that has a real problem the gate below catches. No-op when routing
# already met timing.
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
for {set i 1} {$i <= 8 && $wns < 0} {incr i} {
  phys_opt_design -directive AggressiveExplore
  set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
  puts "=== post-route phys_opt pass $i: WNS = $wns ==="
}

write_checkpoint -force $build/post_route.dcp
report_timing_summary -file $build/timing.rpt -warn_on_violation
report_utilization    -file $build/util.rpt
report_drc            -file $build/drc.rpt
report_datasheet      -file $build/datasheet.rpt   ;# measured per-pin clk->out / setup (PSRAM I/O budget)

# ── Timing gate ─────────────────────────────────────────────────────────────────────
# Refuse to ship a bitstream that missed timing (setup or hold) — a violated build must
# not masquerade as deliverable. This also gives the nexys4.xdc PSRAM I/O budget teeth.
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
puts "=== setup WNS = $wns ns / hold WHS = $whs ns (>= 0 means met) ==="
if {$wns eq "" || $whs eq "" || $wns < 0 || $whs < 0} {
  error "timing NOT met (WNS=$wns WHS=$whs) — no bitstream written"
}

# ── Bitstream ───────────────────────────────────────────────────────────────────────
write_bitstream -force $build/oberon.bit
puts "=== wrote $build/oberon.bit ==="

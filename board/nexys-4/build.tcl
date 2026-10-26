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

# Refuse a stale soc_board.v. It is emitted from the OCaml design, and one older than its
# sources would be yesterday's machine built under today's name. Regenerating takes a few
# seconds, so any design source newer than the emitted file stops the build.
if {![file exists $gen/soc_board.v]} {
  error "no $gen/soc_board.v - run board/nexys-4/gen_verilog.sh first"
}
set emitted [file mtime $gen/soc_board.v]
foreach src [glob -nocomplain $here/../../lib/*.ml $here/*.ml] {
  if {[file mtime $src] > $emitted} {
    error "soc_board.v is older than [file normalize $src] - run board/nexys-4/gen_verilog.sh"
  }
}

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
# The directives. Under default effort the PSRAM I/O budget was once missed by placement
# alone (a long route to a pad, no change in logic); Explore-class effort recovers that.
# At 64 MHz, placement under Explore plateaus just short (WNS -0.071) where ExtraTimingOpt
# closes. If a design change makes 64 MHz refuse under both, the structural relief is a
# register on the instruction cache's fill path (the critical cone), or a slower clock
# (build_config.ml) — not more placer effort.
place_design -directive ExtraTimingOpt
phys_opt_design -directive AggressiveExplore
route_design -directive Explore

# Post-route recovery. The instruction cache's combinational hit path (a 4096-line LUTRAM
# and its output mux) is the critical cone, and routing can land a few picoseconds short of
# it on placement noise. Repeated post-route phys_opt closes that. It is bounded at 8
# passes: a design that still misses has a real problem, which the gate below catches. When
# routing met timing, the loop does nothing.
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

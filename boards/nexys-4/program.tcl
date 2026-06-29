# Program the connected Nexys 4 (XC7A100T) with the built bitstream over JTAG.
# Usage:   vivado -mode batch -source boards/nexys-4/program.tcl
# Assumes the board is connected (FT2232H) and powered. Volatile (SRAM) config — re-run after
# a power-cycle, or write the QSPI flash separately for persistence.

set here [file normalize [file dirname [info script]]]   ;# boards/nexys-4
set bit  [file normalize $here/../_build/nexys-4/oberon.bit]

if {![file exists $bit]} {
  puts "ERROR: $bit not found — run boards/nexys-4/build.tcl first."
  exit 1
}

open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target

set dev [lindex [get_hw_devices xc7a100t*] 0]
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev

set_property PROGRAM.FILE $bit $dev
program_hw_devices $dev
refresh_hw_device $dev

puts "=== programmed $dev with $bit ==="
close_hw_target
disconnect_hw_server

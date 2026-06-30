# Write the built bitstream to the Nexys 4's QSPI configuration flash (Spansion
# S25FL128S, 16 MB) so the board boots Oberon on power-up without a JTAG load.
# Usage:   vivado -mode batch -source boards/nexys-4/flash.tcl
#
# Persistent (unlike program.tcl's volatile SRAM load). The flash WRITE goes over
# JTAG and works in any mode; for the board to BOOT from flash on power-up the MODE
# jumper (JP1) must be set to QSPI. Recoverable: a bad write never bricks the board
# — JTAG is always available, and program.tcl re-loads SRAM directly.
#
# SPIx1 image: the bitstream isn't built with SPI-boot config properties, so x1 is
# the safe default (boots; ~1 s slower config than x4). For x4, set CONFIG_MODE /
# SPI_BUSWIDTH in the xdc and rebuild, then bump -interface below.

set here [file normalize [file dirname [info script]]]   ;# boards/nexys-4
set bit  [file normalize $here/../_build/nexys-4/oberon.bit]
set mcs  [file normalize $here/../_build/nexys-4/oberon.mcs]

if {![file exists $bit]} {
  puts "ERROR: $bit not found — run boards/nexys-4/build.tcl first."
  exit 1
}

# ── Generate the .mcs flash image from the bitstream (offset 0) ──────────────────────
write_cfgmem -force -format mcs -size 16 -interface SPIx1 \
  -loadbit "up 0x0 $bit" -file $mcs
puts "=== wrote $mcs ==="

# ── Connect ──────────────────────────────────────────────────────────────────────────
open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target

set dev [lindex [get_hw_devices xc7a100t*] 0]
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev

# ── Resolve the cfgmem part (error clearly if this Vivado names it differently) ──────
set cfgpart [lindex [get_cfgmem_parts -filter {NAME =~ "s25fl128sxxxxxx0-spi-x1_x2_x4"}] 0]
if {$cfgpart eq ""} {
  set cfgpart [lindex [get_cfgmem_parts -filter {NAME =~ "*s25fl128s*"}] 0]
}
if {$cfgpart eq ""} {
  puts "ERROR: no s25fl128s cfgmem part found in this Vivado install."
  exit 1
}
puts "=== cfgmem part: $cfgpart ==="

# ── Associate the flash with the device and set the program job ──────────────────────
create_hw_cfgmem -hw_device $dev $cfgpart
set cfgmem [get_property PROGRAM.HW_CFGMEM $dev]
set_property PROGRAM.FILES        [list $mcs] $cfgmem
set_property PROGRAM.ADDRESS_RANGE {use_file}  $cfgmem
set_property PROGRAM.ERASE        1 $cfgmem
set_property PROGRAM.CFG_PROGRAM  1 $cfgmem
set_property PROGRAM.VERIFY       1 $cfgmem
set_property PROGRAM.BLANK_CHECK  0 $cfgmem
set_property PROGRAM.UNUSED_PIN_TERMINATION {pull-none} $cfgmem

# ── Program: load the cfgmem helper bitstream into the FPGA, then write flash ─────────
create_hw_bitstream -hw_device $dev [get_property PROGRAM.HW_CFGMEM_BITFILE $dev]
program_hw_devices $dev
refresh_hw_device $dev
program_hw_cfgmem -hw_cfgmem $cfgmem

puts "=== flashed $mcs to $cfgpart on $dev ==="
puts "=== set MODE jumper (JP1) to QSPI, then power-cycle to boot from flash ==="
close_hw_target
disconnect_hw_server

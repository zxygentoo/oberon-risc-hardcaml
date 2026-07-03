## Nexys 4 (original, Cellular-RAM) constraints for the Oberon RISC5 board top.
## Pins from the official Digilent Nexys-4 master XDC, cross-checked against the board.
## Port names match boards/nexys-4/nexys4_top.v.
##
## The single PS/2 port (PS2Clk=F4, PS2Data=B2) is wired to the MOUSE (open-drain,
## bidirectional via the top's IOBUFs); the keyboard moves to the 2nd-port PS/2 Pmod later.

## ── Clock: 100 MHz on E3 ─────────────────────────────────────────────────────────────
set_property -dict {PACKAGE_PIN E3 IOSTANDARD LVCMOS33} [get_ports CLK100MHZ]
create_clock -period 10.000 -name clk100 [get_ports CLK100MHZ]

## The MMCM's 60 MHz and 65 MHz outputs are auto-derived. They drive separate domains bridged
## only by VID's CDC handshakes (data stable for many cycles before sampling), so treat them as
## asynchronous for timing (don't time the cross-domain paths).
set_clock_groups -asynchronous \
  -group [get_clocks -of_objects [get_pins bufg_25/O]] \
  -group [get_clocks -of_objects [get_pins bufg_65/O]]

## VID's pclk->clk request synchroniser (lib/vid.ml pulse_sync: req_toggle -> sync0/sync1/
## sync2): mark the synchroniser flops ASYNC_REG so the tools pack them tightly (maximising
## metastability MTBF) and never retime/optimise them away — the silicon-robustness half of
## the flicker fix (the CDC redesign itself is in vid.ml; AGENT.md §8).
set_property ASYNC_REG true \
  [get_cells -hierarchical -filter {NAME =~ "*sync0*" || NAME =~ "*sync1*" || NAME =~ "*sync2*"}]

## NB: a `set_max_delay -datapath_only` to bound the req_toggle->sync0 first hop would be
## INERT here — set_clock_groups (above) outranks set_max_delay in Vivado, so it cuts the
## path first and the max_delay binds zero endpoints (verified: the routed path reports
## Slack: inf). ASYNC_REG keeps the placer packing sync0/1/2 tight (the routed first hop is
## ~0.95 ns, far under any clock period), so the hop is robust without it. If clk25 is ever
## pushed hard enough to want an explicit bound, drop the clk25<->clk65 pair from the
## clock_groups above and constrain *every* crossing (both directions) with per-path
## set_max_delay -datapath_only instead — only then does max_delay actually apply.

## ── PSRAM async-interface I/O budget ─────────────────────────────────────────────────
## Cellram holds each 16-bit phase for read_cycles = 5 clk = 83.3 ns at 60 MHz and samples
## MemDB at the phase-end edge. The M45W8MW16-70 needs address/CE valid 70 ns AT THE CHIP
## (tAA/tCO), so the FPGA round trip must fit the remainder:
##   t_out(reg -> addr/ctl pad) + board flight + t_in(MemDB pad -> deepest consumer FF)
##     <= 83.3 - 70 = 13.3 ns.
## Three groups (an unconstrained I/O path is never timed at all — before this block the
## margin was hand arithmetic only):
##   1. Read-critical OUTPUTS <= 6.7 ns: MemAdr (tAA), RamCEn (tCO) and RamLBn/UBn
##      (tBA = 70 ns too, and they DO transition on the first read after a byte store).
##      NOT RamOEn (tOE = 20 ns only) or RamWEn (write-path) — those sit in group 3.
##      Needs the FAST/16 drivers below; at default drive the strobes alone are ~7.4 ns
##      and the two groups cannot both fit 13.3.
##   2. MemDB INPUT <= 6.6 ns. NB the budget must cover the DEEPEST same-edge consumer,
##      not just Cellram's lo/rdata capture flop: on the load-retire cycle the raw pad
##      value flows pad -> rdata -> inbus -> regmux -> flags/SPC in one cycle (~5.7 ns
##      routed), and all of it sits inside the data-valid-to-capture-edge window.
##   3. Loose sanity group <= 12.0 ns: MemDB out + tristate (write-path — tDW = 20 ns
##      before WEn rise, ~67 ns after launch — plus turnaround), RamOEn (tOE = 20 ns:
##      ~63 ns of real budget) and RamWEn (write pulse geometry, whole-cycle margins).
##      Keeping any of these in group 1 over-constrains the router for nothing (it cost
##      -0.7 ns of fake violations and pressured the real clk25 paths).
## 1 + 2 = 13.3 exactly — the demand is genuinely knife-edge at the slow corner (the
## routed halves land within ~0.3 ns of their bounds); board flight (~0.3 ns round trip, the chip sits next to the
## FPGA) eats into slack rather than being reserved. If either group ever misses:
## rebalance the split, or bump read_cycles to 6 in emit_board_verilog.ml (100 ns window
## -> ~30 ns budget). tWP is comfortable by construction (WEn low 4 of 5 cycles = 67 ns
## >> 45 ns, a full cycle of data hold past WEn rise).
## Fast/strong drivers on the whole PSRAM interface: the OBUF is the dominant t_out
## term (~3 ns of the strobes' ~4.4 ns logic at the default DRIVE 12 / SLOW slew), and
## the traces are short point-to-point to the adjacent chip (no connector), so FAST/16
## is SI-comfortable and shaves ~1 ns off every read-critical output.
set_property SLEW FAST [get_ports {MemAdr[*] MemDB[*] RamCEn RamOEn RamWEn RamLBn RamUBn}]
set_property DRIVE 16  [get_ports {MemAdr[*] MemDB[*] RamCEn RamOEn RamWEn RamLBn RamUBn}]

set clk_sys [get_clocks -of_objects [get_pins bufg_25/O]]
set_max_delay 6.700 -datapath_only -from $clk_sys \
  -to [get_ports {MemAdr[*] RamCEn RamLBn RamUBn}]
set_max_delay 6.600 -datapath_only -from [get_ports {MemDB[*]}] -to $clk_sys
set_max_delay 12.000 -datapath_only -from $clk_sys \
  -to [get_ports {MemDB[*] RamOEn RamWEn}]

## ── Reset button (active-low) ────────────────────────────────────────────────────────
set_property -dict {PACKAGE_PIN C12 IOSTANDARD LVCMOS33} [get_ports btnCpuReset]

## ── Slide switches SW0..7 (active-high; sw[7] = video invert) ─────────────────────────
set_property -dict {PACKAGE_PIN U9  IOSTANDARD LVCMOS33} [get_ports {sw[0]}]
set_property -dict {PACKAGE_PIN U8  IOSTANDARD LVCMOS33} [get_ports {sw[1]}]
set_property -dict {PACKAGE_PIN R7  IOSTANDARD LVCMOS33} [get_ports {sw[2]}]
set_property -dict {PACKAGE_PIN R6  IOSTANDARD LVCMOS33} [get_ports {sw[3]}]
set_property -dict {PACKAGE_PIN R5  IOSTANDARD LVCMOS33} [get_ports {sw[4]}]
set_property -dict {PACKAGE_PIN V7  IOSTANDARD LVCMOS33} [get_ports {sw[5]}]
set_property -dict {PACKAGE_PIN V6  IOSTANDARD LVCMOS33} [get_ports {sw[6]}]
set_property -dict {PACKAGE_PIN V5  IOSTANDARD LVCMOS33} [get_ports {sw[7]}]

## ── Nav buttons -> soc_board.btn[3:0] = {btnU, btnD, btnL, btnR} ──────────────────────
set_property -dict {PACKAGE_PIN F15 IOSTANDARD LVCMOS33} [get_ports btnU]
set_property -dict {PACKAGE_PIN V10 IOSTANDARD LVCMOS33} [get_ports btnD]
set_property -dict {PACKAGE_PIN T16 IOSTANDARD LVCMOS33} [get_ports btnL]
set_property -dict {PACKAGE_PIN R10 IOSTANDARD LVCMOS33} [get_ports btnR]

## ── LEDs LD0..15 ─────────────────────────────────────────────────────────────────────
set_property -dict {PACKAGE_PIN T8  IOSTANDARD LVCMOS33} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN V9  IOSTANDARD LVCMOS33} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN R8  IOSTANDARD LVCMOS33} [get_ports {led[2]}]
set_property -dict {PACKAGE_PIN T6  IOSTANDARD LVCMOS33} [get_ports {led[3]}]
set_property -dict {PACKAGE_PIN T5  IOSTANDARD LVCMOS33} [get_ports {led[4]}]
set_property -dict {PACKAGE_PIN T4  IOSTANDARD LVCMOS33} [get_ports {led[5]}]
set_property -dict {PACKAGE_PIN U7  IOSTANDARD LVCMOS33} [get_ports {led[6]}]
set_property -dict {PACKAGE_PIN U6  IOSTANDARD LVCMOS33} [get_ports {led[7]}]
set_property -dict {PACKAGE_PIN V4  IOSTANDARD LVCMOS33} [get_ports {led[8]}]
set_property -dict {PACKAGE_PIN U3  IOSTANDARD LVCMOS33} [get_ports {led[9]}]
set_property -dict {PACKAGE_PIN V1  IOSTANDARD LVCMOS33} [get_ports {led[10]}]
set_property -dict {PACKAGE_PIN R1  IOSTANDARD LVCMOS33} [get_ports {led[11]}]
set_property -dict {PACKAGE_PIN P5  IOSTANDARD LVCMOS33} [get_ports {led[12]}]
set_property -dict {PACKAGE_PIN U1  IOSTANDARD LVCMOS33} [get_ports {led[13]}]
set_property -dict {PACKAGE_PIN R2  IOSTANDARD LVCMOS33} [get_ports {led[14]}]
set_property -dict {PACKAGE_PIN P2  IOSTANDARD LVCMOS33} [get_ports {led[15]}]

## ── USB-UART ─────────────────────────────────────────────────────────────────────────
set_property -dict {PACKAGE_PIN C4  IOSTANDARD LVCMOS33} [get_ports RsRx]
set_property -dict {PACKAGE_PIN D4  IOSTANDARD LVCMOS33} [get_ports RsTx]

## ── VGA (4-4-4; we drive 1 bpp mono onto all 12) ─────────────────────────────────────
set_property -dict {PACKAGE_PIN A3  IOSTANDARD LVCMOS33} [get_ports {vgaRed[0]}]
set_property -dict {PACKAGE_PIN B4  IOSTANDARD LVCMOS33} [get_ports {vgaRed[1]}]
set_property -dict {PACKAGE_PIN C5  IOSTANDARD LVCMOS33} [get_ports {vgaRed[2]}]
set_property -dict {PACKAGE_PIN A4  IOSTANDARD LVCMOS33} [get_ports {vgaRed[3]}]
set_property -dict {PACKAGE_PIN C6  IOSTANDARD LVCMOS33} [get_ports {vgaGreen[0]}]
set_property -dict {PACKAGE_PIN A5  IOSTANDARD LVCMOS33} [get_ports {vgaGreen[1]}]
set_property -dict {PACKAGE_PIN B6  IOSTANDARD LVCMOS33} [get_ports {vgaGreen[2]}]
set_property -dict {PACKAGE_PIN A6  IOSTANDARD LVCMOS33} [get_ports {vgaGreen[3]}]
set_property -dict {PACKAGE_PIN B7  IOSTANDARD LVCMOS33} [get_ports {vgaBlue[0]}]
set_property -dict {PACKAGE_PIN C7  IOSTANDARD LVCMOS33} [get_ports {vgaBlue[1]}]
set_property -dict {PACKAGE_PIN D7  IOSTANDARD LVCMOS33} [get_ports {vgaBlue[2]}]
set_property -dict {PACKAGE_PIN D8  IOSTANDARD LVCMOS33} [get_ports {vgaBlue[3]}]
set_property -dict {PACKAGE_PIN B11 IOSTANDARD LVCMOS33} [get_ports Hsync]
set_property -dict {PACKAGE_PIN B12 IOSTANDARD LVCMOS33} [get_ports Vsync]

## ── PS/2 (single port via the USB-HID PIC; wired to the mouse) ───────────────────────
## Open-drain bidirectional (IOBUFs in the top); PULLUP holds the idle-high line when
## neither side drives. PS2Clk=F4, PS2Data=B2 per the Digilent master XDC.
set_property -dict {PACKAGE_PIN F4 IOSTANDARD LVCMOS33 PULLUP true} [get_ports PS2Clk]
set_property -dict {PACKAGE_PIN B2 IOSTANDARD LVCMOS33 PULLUP true} [get_ports PS2Data]

## ── microSD (SPI mode) ───────────────────────────────────────────────────────────────
set_property -dict {PACKAGE_PIN B1  IOSTANDARD LVCMOS33} [get_ports sd_sck]
set_property -dict {PACKAGE_PIN C1  IOSTANDARD LVCMOS33} [get_ports sd_cmd]
set_property -dict {PACKAGE_PIN C2  IOSTANDARD LVCMOS33 PULLUP true} [get_ports sd_dat0]
set_property -dict {PACKAGE_PIN D2  IOSTANDARD LVCMOS33} [get_ports sd_dat3]
set_property -dict {PACKAGE_PIN E2  IOSTANDARD LVCMOS33} [get_ports sd_reset]

## ── Cellular RAM control ─────────────────────────────────────────────────────────────
set_property -dict {PACKAGE_PIN H14 IOSTANDARD LVCMOS33} [get_ports RamOEn]
set_property -dict {PACKAGE_PIN R11 IOSTANDARD LVCMOS33} [get_ports RamWEn]
set_property -dict {PACKAGE_PIN L18 IOSTANDARD LVCMOS33} [get_ports RamCEn]
set_property -dict {PACKAGE_PIN J15 IOSTANDARD LVCMOS33} [get_ports RamLBn]
set_property -dict {PACKAGE_PIN J13 IOSTANDARD LVCMOS33} [get_ports RamUBn]
set_property -dict {PACKAGE_PIN J14 IOSTANDARD LVCMOS33} [get_ports RamCRE]
set_property -dict {PACKAGE_PIN T13 IOSTANDARD LVCMOS33} [get_ports RamADVn]
set_property -dict {PACKAGE_PIN T15 IOSTANDARD LVCMOS33} [get_ports RamCLK]

## ── Cellular RAM address MemAdr[22:0] ────────────────────────────────────────────────
set_property -dict {PACKAGE_PIN J18 IOSTANDARD LVCMOS33} [get_ports {MemAdr[0]}]
set_property -dict {PACKAGE_PIN H17 IOSTANDARD LVCMOS33} [get_ports {MemAdr[1]}]
set_property -dict {PACKAGE_PIN H15 IOSTANDARD LVCMOS33} [get_ports {MemAdr[2]}]
set_property -dict {PACKAGE_PIN J17 IOSTANDARD LVCMOS33} [get_ports {MemAdr[3]}]
set_property -dict {PACKAGE_PIN H16 IOSTANDARD LVCMOS33} [get_ports {MemAdr[4]}]
set_property -dict {PACKAGE_PIN K15 IOSTANDARD LVCMOS33} [get_ports {MemAdr[5]}]
set_property -dict {PACKAGE_PIN K13 IOSTANDARD LVCMOS33} [get_ports {MemAdr[6]}]
set_property -dict {PACKAGE_PIN N15 IOSTANDARD LVCMOS33} [get_ports {MemAdr[7]}]
set_property -dict {PACKAGE_PIN V16 IOSTANDARD LVCMOS33} [get_ports {MemAdr[8]}]
set_property -dict {PACKAGE_PIN U14 IOSTANDARD LVCMOS33} [get_ports {MemAdr[9]}]
set_property -dict {PACKAGE_PIN V14 IOSTANDARD LVCMOS33} [get_ports {MemAdr[10]}]
set_property -dict {PACKAGE_PIN V12 IOSTANDARD LVCMOS33} [get_ports {MemAdr[11]}]
set_property -dict {PACKAGE_PIN P14 IOSTANDARD LVCMOS33} [get_ports {MemAdr[12]}]
set_property -dict {PACKAGE_PIN U16 IOSTANDARD LVCMOS33} [get_ports {MemAdr[13]}]
set_property -dict {PACKAGE_PIN R15 IOSTANDARD LVCMOS33} [get_ports {MemAdr[14]}]
set_property -dict {PACKAGE_PIN N14 IOSTANDARD LVCMOS33} [get_ports {MemAdr[15]}]
set_property -dict {PACKAGE_PIN N16 IOSTANDARD LVCMOS33} [get_ports {MemAdr[16]}]
set_property -dict {PACKAGE_PIN M13 IOSTANDARD LVCMOS33} [get_ports {MemAdr[17]}]
set_property -dict {PACKAGE_PIN V17 IOSTANDARD LVCMOS33} [get_ports {MemAdr[18]}]
set_property -dict {PACKAGE_PIN U17 IOSTANDARD LVCMOS33} [get_ports {MemAdr[19]}]
set_property -dict {PACKAGE_PIN T10 IOSTANDARD LVCMOS33} [get_ports {MemAdr[20]}]
set_property -dict {PACKAGE_PIN M16 IOSTANDARD LVCMOS33} [get_ports {MemAdr[21]}]
set_property -dict {PACKAGE_PIN U13 IOSTANDARD LVCMOS33} [get_ports {MemAdr[22]}]

## ── Cellular RAM data MemDB[15:0] (bidirectional) ────────────────────────────────────
set_property -dict {PACKAGE_PIN R12 IOSTANDARD LVCMOS33} [get_ports {MemDB[0]}]
set_property -dict {PACKAGE_PIN T11 IOSTANDARD LVCMOS33} [get_ports {MemDB[1]}]
set_property -dict {PACKAGE_PIN U12 IOSTANDARD LVCMOS33} [get_ports {MemDB[2]}]
set_property -dict {PACKAGE_PIN R13 IOSTANDARD LVCMOS33} [get_ports {MemDB[3]}]
set_property -dict {PACKAGE_PIN U18 IOSTANDARD LVCMOS33} [get_ports {MemDB[4]}]
set_property -dict {PACKAGE_PIN R17 IOSTANDARD LVCMOS33} [get_ports {MemDB[5]}]
set_property -dict {PACKAGE_PIN T18 IOSTANDARD LVCMOS33} [get_ports {MemDB[6]}]
set_property -dict {PACKAGE_PIN R18 IOSTANDARD LVCMOS33} [get_ports {MemDB[7]}]
set_property -dict {PACKAGE_PIN F18 IOSTANDARD LVCMOS33} [get_ports {MemDB[8]}]
set_property -dict {PACKAGE_PIN G18 IOSTANDARD LVCMOS33} [get_ports {MemDB[9]}]
set_property -dict {PACKAGE_PIN G17 IOSTANDARD LVCMOS33} [get_ports {MemDB[10]}]
set_property -dict {PACKAGE_PIN M18 IOSTANDARD LVCMOS33} [get_ports {MemDB[11]}]
set_property -dict {PACKAGE_PIN M17 IOSTANDARD LVCMOS33} [get_ports {MemDB[12]}]
set_property -dict {PACKAGE_PIN P18 IOSTANDARD LVCMOS33} [get_ports {MemDB[13]}]
set_property -dict {PACKAGE_PIN N17 IOSTANDARD LVCMOS33} [get_ports {MemDB[14]}]
set_property -dict {PACKAGE_PIN P17 IOSTANDARD LVCMOS33} [get_ports {MemDB[15]}]

## ── Configuration / bitstream housekeeping ───────────────────────────────────────────
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property CFGBVS VCCO [current_design]

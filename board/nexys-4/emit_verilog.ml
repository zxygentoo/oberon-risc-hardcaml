(* Phase 7 — emit the synthesizable board SoC ({!Nexys4_board.Soc}) as Verilog, with the
   real boot ROM baked in. The hand-written nexys4_top.v (same dir) wraps the emitted
   [soc_board] module with the vendor primitives (MMCM, IOBUFs). Prints to stdout;
   gen_verilog.sh redirects it to board/_generated/nexys-4/soc_board.v.

   Lives in the board layer (not test/): it emits *this board's* SoC and sits next to the
   gen_verilog.sh / build.tcl / nexys4_top.v that consume it. The ROM image comes from the
   design library ({!Risc5.Rom}), so the board emit needs no software oracle.

   Parameters baked into the netlist: {!Nexys4_board.Build_config.shipped} (64000
   clocks/ms; PSRAM phases read 6 / write 5 cycles; each knob's rationale sits there) —
   the same value the board gates in test/board/nexys-4 boot.

   NB (feat/clock-push): retuned for a 64 MHz system clock (nexys4_top.v MMCM VCO 1040,
   CLKOUT0_DIVIDE_F = 16.250 — the VCO that keeps 64 and the 65 pixel clock both exact);
   before that, feat/fast-clock's 60 MHz (VCO 780 ÷ 13.000), enabled by the pipelined DSP
   multiplies (mul_stages:2) that move the multiply off the critical path. At 64 MHz
   (15.625 ns/cycle) the read phase keeps 6 cycles (93.75 ns = 70 for the chip + 23.75 for
   the FPGA round trip; the xdc groups tightened 12.0 → 11.7 to fit) and the SPI slow
   divider stays ÷256 (250 kHz ≤ the 400 kHz SD-init ceiling). Timing note: 64 closes at
   WNS +0.004 only under build.tcl's ExtraTimingOpt placement (Explore plateaus at −0.071)
   — the thinnest rung of the ladder; the structural relief if a rebuild ever refuses is
   registering the icache fill path (or reverting a rung). Revert to 62.4 MHz:
   clocks_per_ms 62400, uart_baud 541/541, MMCM VCO 780 (MULT_F 39.000) / CLKOUT0 12.500 /
   CLKOUT1 12, xdc groups back to 12.0. Revert to 60: likewise with clocks_per_ms 60000,
   uart_baud 521/521, CLKOUT0 13.000. Revert to 50: clocks_per_ms 50000, read/write_cycles
   4, spi_slow_div_log2 7, MMCM VCO 650 (DIVCLK 1 / MULT 6.5), CLKOUT1_DIVIDE 10. *)

open Hardcaml
module Soc = Nexys4_board.Soc
module Circ = Circuit.With_interface (Soc.I) (Soc.O)

let () =
  let circuit =
    Circ.create_exn
    (* the EMITTED Verilog module keeps the name "soc_board" (decoupled from the OCaml
       module, now [Soc]): nexys4_top.v instantiates it by this name and the whole Vivado
       flow reads board/_generated/nexys-4/soc_board.v — renaming the artifact would churn
       the board flow for nothing. *)
      ~name:"soc_board"
      (Soc.create_config ~contents:Risc5.Rom.bootloader Nexys4_board.Build_config.shipped)
  in
  Rtl.print Verilog circuit
;;

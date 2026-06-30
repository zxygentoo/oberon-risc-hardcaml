(* Phase 7 — emit the synthesizable board SoC ({!Nexys4_board.Soc_board}) as Verilog, with
   the real boot ROM baked in. The hand-written boards/nexys-4/nexys4_top.v wraps the
   emitted [soc_board] module with the vendor primitives (MMCM, IOBUFs). Prints to stdout;
   boards/nexys-4/gen_verilog.sh redirects it to boards/_generated/nexys-4/soc_board.v.

   Parameters baked into the netlist: 50000 clocks/ms (1 ms at 50 MHz); 4-cycle PSRAM
   phases (80 ns > the chip's 70 ns at 50 MHz). Tune read/write cycles here if hardware
   needs it.

   NB (Phase-9 scratch): retuned for a 50 MHz system clock (nexys4_top.v MMCM
   CLKOUT0_DIVIDE_F = 13.000). Phase length is held at 80 ns wall-clock (4 cycles × 20
   ns), so every memory / video-DMA timing is identical to the 25 MHz build — only CPU
   compute doubles. Revert to 25 MHz: clocks_per_ms 25000, read/write_cycles 2, divider
   26.000. *)

open Hardcaml
module Soc_board = Nexys4_board.Soc_board
module Circ = Circuit.With_interface (Soc_board.I) (Soc_board.O)

let () =
  let circuit =
    Circ.create_exn
      ~name:"soc_board"
      (Soc_board.create
         ~contents:Oracle.Boot_rom.bootloader
         ~clocks_per_ms:50000
           (* 4 cycles/phase = 80 ns at 50 MHz (20 ns) > the chip's 70 ns (in spec), and
              identical wall-clock to the old 2-cycle-at-25-MHz phase — so the worst-case
              framebuffer fetch still fits under VID's ~477 ns xfer deadline even behind
              one CPU access (the video-flicker margin, PHASE7 §9.2). 3 cycles = 60 ns is
              too short at 50 MHz; raise to 5 (100 ns) if PSRAM reads turn flaky on HW. *)
         ~read_cycles:4
         ~write_cycles:4
           (* SPI slow divider clk÷128 (vs the faithful ÷64): keeps the SD-init clock at
              390.6 kHz (≤ the 400 kHz ceiling) now that the system clock is 50 MHz. FAST
              stays clk÷3 = 16.7 MHz, under the 25 MHz SD limit. (PHASE9 §SPI.) *)
         ~spi_slow_div_log2:7)
  in
  Rtl.print Verilog circuit
;;

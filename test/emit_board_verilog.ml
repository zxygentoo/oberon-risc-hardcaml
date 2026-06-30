(* Phase 7 — emit the synthesizable board SoC ({!Nexys4_board.Soc_board}) as Verilog, with
   the real boot ROM baked in. The hand-written boards/nexys-4/nexys4_top.v wraps the
   emitted [soc_board] module with the vendor primitives (MMCM, IOBUFs). Prints to stdout;
   boards/nexys-4/gen_verilog.sh redirects it to boards/_generated/nexys-4/soc_board.v.

   Parameters baked into the netlist: 25000 clocks/ms (1 ms at 25 MHz); 2-cycle PSRAM
   phases (80 ns > the chip's 70 ns at 25 MHz). Tune read/write cycles here if hardware
   needs it. *)

open Hardcaml
module Soc_board = Nexys4_board.Soc_board
module Circ = Circuit.With_interface (Soc_board.I) (Soc_board.O)

let () =
  let circuit =
    Circ.create_exn
      ~name:"soc_board"
      (Soc_board.create
         ~contents:Oracle.Boot_rom.bootloader
         ~clocks_per_ms:25000
           (* 2 cycles/phase = 80 ns > the chip's 70 ns (in spec), and the worst-case
              framebuffer fetch then fits under VID's ~477 ns xfer deadline even behind
              one CPU access — the video-flicker margin (PHASE7 §9.2). The board boot
              checkpoint runs at 2 too. Raise to 3 (120 ns) if PSRAM reads turn flaky on
              HW. *)
         ~read_cycles:2
         ~write_cycles:2)
  in
  Rtl.print Verilog circuit
;;

(** Video controller — a faithful port of [VID60.v] (1024x768 @ 60 Hz, 1 bpp mono).

    Two jobs on two clocks: a VGA timing generator (hsync/vsync/blank + a pixel shift-out)
    on the 65 MHz pixel clock [pclk], and a framebuffer DMA that reads one 32-bit word (=
    32 pixels) from main memory every 32 pixels on the 25 MHz system clock [clk]. The DMA
    request [req] is the core's video stall ([stallX]); [vidadr] is the framebuffer word
    address; [viddata] is the word read back, shifted out one pixel per [pclk].

    [VID60.v] generates [pclk] internally with a Xilinx [DCM] (x13/5 of [clk]); that
    primitive is the Phase-7 board shim (the Nexys MMCM), so here [pclk] is an input.
    There is no reset — the raster counters free-run from their power-on (zero) state. *)

open Hardcaml

module I : sig
  type 'a t =
    { clk : 'a (* 25 MHz system/memory clock: the DMA handshake + [vidbuf] live here *)
    ; pclk : 'a (* 65 MHz pixel clock (DCM/MMCM-generated; a board-shim input here) *)
    ; inv : 'a (* invert video: white-on-black vs black-on-white *)
    ; viddata : 'a (* main-memory read data, latched into [vidbuf] when [req] fires *)
    }
  [@@deriving hardcaml]
end

module O : sig
  type 'a t =
    { req : 'a (* SRAM read request = [stallX] into the core (one [clk] cycle / 32 px) *)
    ; vidadr : 'a (* framebuffer word address for the DMA read *)
    ; hsync : 'a (* horizontal sync, active low *)
    ; vsync : 'a (* vertical sync, active low *)
    ; rgb : 'a (* the 1 bpp pixel replicated across RGBW (= 6) pins *)
    }
  [@@deriving hardcaml]
end

(** [create i] builds the controller, cycle-faithful to [VID60.v]. NB the async-set CDC
    flop [req1] (RTL [always @(posedge req0, posedge clk)]) is modelled as a [pclk]-domain
    capture: Cyclesim samples async reset only at the clock edge, so a literal
    transcription would drop a request pulse that lands between two [clk] edges. The
    pixel/sync datapath is a direct transliteration. The Verilator co-sim proves
    output-equivalence to [VID60.v]. *)
val create : Signal.t I.t -> Signal.t O.t

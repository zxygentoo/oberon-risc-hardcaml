(** The board SoC: the same machine as {!Risc5.Soc}, with main memory behind the
    {!Cellram} PSRAM controller instead of single-cycle RAM. The MMIO map, the
    peripherals, the timer and the video raster are the same. What differs:
    - the core runs on a clock enable driven by {!Cellram}, and so freezes while a PSRAM
      access is in flight; its [stall_x] is tied off, video being arbitrated in Cellram;
    - main memory and the framebuffer DMA go through Cellram, which drives the chip's pins
      exposed here. Boot-ROM fetches and MMIO accesses complete on the FPGA in one cycle;
    - an MMIO store goes only to its peripheral. {!Risc5.Soc}, like the original, also
      writes it into the aliased RAM word; Oberon never reads those words back;
    - the framebuffer word is latched into {!Risc5.Video} on the controller's acknowledge;
    - the timer interrupt is {e stretched}. [RISC5.v] captures its interrupt every clock,
      but here the core's capture registers are frozen with the rest of it, and a one-
      clock tick arriving in a frozen cycle would be lost. The request is therefore held
      until an enabled cycle has sampled it: still one edge per tick, and identical to the
      original whenever the core is not frozen.

    The chip is outside the FPGA: in simulation a {!Cellram_model} is wired to these pins,
    and on the board the Verilog top level wires them to I/O buffers.

    [contents] is the boot-ROM image; everything else that varies arrives in one
    {!Build_config.t}. *)

open Hardcaml

module I : sig
  type 'a t =
    { clock : 'a (** the system clock *)
    ; pclk : 'a (** 65 MHz pixel clock (MMCM-generated on the board) *)
    ; rst_n : 'a (** reset, active low *)
    ; miso : 'a (** SPI / SD-card data in (already ANDed SD & net) *)
    ; rxd : 'a (** RS-232 receive *)
    ; btn : 'a (** buttons, logical/active-high *)
    ; sw : 'a (** switches, logical/active-high *)
    ; gpio_in : 'a (** resolved GPIO pad inputs *)
    ; ps2c : 'a (** PS/2 keyboard clock *)
    ; ps2d : 'a (** PS/2 keyboard data *)
    ; msclk : 'a (** PS/2 mouse clock, resolved open-drain line in *)
    ; msdat : 'a (** PS/2 mouse data, resolved open-drain line in *)
    ; mem_dq_i : 'a (** 16-bit PSRAM data read back (from the top's IOBUFs) *)
    }
  [@@deriving hardcaml]
end

module O : sig
  type 'a t =
    { mosi : 'a (** SPI master out *)
    ; sclk : 'a (** SPI clock *)
    ; sd_cs : 'a (** SD-card chip select, active low (= [~spiCtrl[0]]) *)
    ; txd : 'a (** RS-232 transmit *)
    ; leds : 'a (** 8 user LEDs *)
    ; gpio_out : 'a (** GPIO drive value *)
    ; gpio_oe : 'a (** GPIO output-enable / direction *)
    ; hsync : 'a (** VGA horizontal sync, active low *)
    ; vsync : 'a (** VGA vertical sync, active low *)
    ; rgb : 'a (** 1 bpp pixel replicated across the RGB pins *)
    ; msclk_oe : 'a (** mouse msclk open-drain: 1 = host pulls low *)
    ; msdat_oe : 'a (** mouse msdat open-drain: 1 = host pulls low *)
    ; mouse_dbg : 'a
    (** the mouse state word, as the CPU reads it at MMIO word 6, brought out for the
        board's LEDs during bring-up; not part of the machine *)
    ; mem_adr : 'a (** PSRAM address [MemAdr[22:0]] *)
    ; mem_dq_o : 'a (** PSRAM write data [16] *)
    ; mem_dq_t : 'a (** PSRAM data tristate: 1 = hi-Z (read), 0 = drive (write) *)
    ; ram_ce_n : 'a (** PSRAM chip enable, active low *)
    ; ram_oe_n : 'a (** PSRAM output enable, active low *)
    ; ram_we_n : 'a (** PSRAM write enable, active low *)
    ; ram_ub_n : 'a (** PSRAM upper-byte enable, active low *)
    ; ram_lb_n : 'a (** PSRAM lower-byte enable, active low *)
    }
  [@@deriving hardcaml]
end

(** [create ~contents c i] elaborates the board SoC in configuration [c] — the emitter
    passes {!Build_config.shipped}. *)
val create : contents:int array -> Build_config.t -> Signal.t I.t -> Signal.t O.t

(** Test scaffolding, not hardware: the board SoC closed with the {!Cellram_model} on its
    PSRAM pins, and the idle levels of its inputs — shared by the tests in this file and
    every harness in test/board. *)
module For_tests : sig
  module Tb : sig
    module I : sig
      type 'a t =
        { clock : 'a
        ; pclk : 'a
        ; rst_n : 'a
        ; miso : 'a
        ; rxd : 'a
        ; btn : 'a
        ; sw : 'a
        ; gpio_in : 'a
        ; ps2c : 'a
        ; ps2d : 'a
        ; msclk : 'a
        ; msdat : 'a
        }
      [@@deriving hardcaml]
    end

    module O : sig
      type 'a t =
        { leds : 'a (** the [Lreg] latch (the MMIO test's observable) *)
        ; sclk : 'a (** SPI clock — the boot gates drive their SD bridge from it *)
        ; hsync : 'a
        ; vsync : 'a
        ; rgb : 'a
        (** [hsync], [vsync] and [rgb] are observed so that the simulator does not prune
            the pixel path, and the {!Framebuf} RAMs with it: logic that reaches no output
            is removed, and a lookup of those memories by name then finds nothing. *)
        }
      [@@deriving hardcaml]
    end

    (** [create ~contents c i] closes {!Soc.create} with the chip model. [?addr_bits]
        sizes the model: 12 by default, enough for the tests here; the boot gates pass 19,
        the whole 1 MiB.

        [?datasheet_chip] (default [false]: a chip that answers at once) holds the model,
        at [c]'s clock, to the datasheet's read access time and write pulse width, and to
        the write access time the shipped configuration provides (62 ns; see
        {!Cellram_model.create}). *)
    val create
      :  contents:int array
      -> ?addr_bits:int
      -> ?datasheet_chip:bool
      -> Build_config.t
      -> Signal.t I.t
      -> Signal.t O.t
  end

  (** drive every input to its idle level ([rst_n] excluded — reset sequencing belongs to
      the test). NB [pclk] low does not quiet the video DMA under Cyclesim's one-domain
      semantics: it contends for the PSRAM port in every sim of a configuration without
      [fb_bram]. *)
  val drive_idle : Bits.t ref Tb.I.t -> unit
end

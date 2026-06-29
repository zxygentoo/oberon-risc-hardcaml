(** [Soc_board] — the Phase-7 board variant of [Soc]: the same RISC5Top SoC, but with main
    memory behind the {!Cellram} PSRAM controller instead of the single-cycle BRAM [Sram].

    Differences from [Soc] (everything else — the MMIO map, peripherals, timer, video
    raster — is identical):
    - the core runs on a clock-enable ([ce]) driven by {!Cellram}, so it freezes during
      PSRAM wait-states (AGENT.md §3); its [stall_x] is tied off (video is arbitrated in
      {!Cellram}, not via the core's stall);
    - reads/writes of main memory, and the video framebuffer DMA, go through {!Cellram},
      which drives the external chip pins exposed here ([mem_adr]/[mem_dq_*]/[ram_*_n]).
      Boot-ROM fetches and MMIO accesses take the controller's on-chip fast path;
    - the framebuffer word is latched into [Vid] on the controller's [vid_ack].

    The chip itself is off-FPGA: in simulation a {!Cellram_model} is wired to these pins
    (the board boot checkpoint); on the board the Verilog top wires IOBUFs. The
    synthesizable design here holds no main-memory array. [contents] is the boot-ROM
    image; [clocks_per_ms] the ms-timer prescaler (25000 = 1 ms at 25 MHz);
    [read_cycles]/[write_cycles] the PSRAM phase lengths. *)

open Hardcaml

module I : sig
  type 'a t =
    { clock : 'a (** 25 MHz system / memory clock *)
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
    (** the mouse state word [{run, btns[2:0], 2'b0, y[9:0], 2'b0, x[9:0]}] (=
        [mouse.out], the same value the CPU reads at MMIO word 6) routed out for the
        board's bring-up LEDs. Pure instrumentation — not part of the functional path. *)
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

val create
  :  contents:int array
  -> ?clocks_per_ms:int
  -> ?read_cycles:int
  -> ?write_cycles:int
  -> Signal.t I.t
  -> Signal.t O.t

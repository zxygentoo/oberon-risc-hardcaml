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
    - the framebuffer word is latched into [Vid] on the controller's [vid_ack];
    - the ms-timer IRQ is {e stretched}: [RISC5.v] latches its interrupt capture every
      clock (even under stallX), but here the core's [irq1]/[int_pnd] flops are ce-gated,
      so a 1-clock tick landing in a frozen (ce=0) cycle would be lost. The board holds
      the request until a ce=1 cycle samples it — one edge per tick, and identical to
      [irq = limit] whenever the core is not frozen (so the lib [Soc] is unaffected).

    The chip itself is off-FPGA: in simulation a {!Cellram_model} is wired to these pins
    (the board boot checkpoint); on the board the Verilog top wires IOBUFs. The
    synthesizable design here holds no main-memory array. [contents] is the boot-ROM
    image; [clocks_per_ms] the ms-timer prescaler (25000 = 1 ms at 25 MHz);
    [read_cycles]/[write_cycles] the PSRAM phase lengths (default {!Cellram}'s — 2);
    [spi_slow_div_log2] the SPI slow-divider depth (default 6 = clk÷64 = {!Spi}/[SPI.v];
    the 50 MHz build passes 7 = clk÷128 to keep SD init ≤400 kHz); [fast_mul] (default
    [false], Phase 9) swaps the core's iterative multiplier for the DSP-backed
    {!Risc5_core.create}[ ?fast_mul] one — see there; [icache] (default [false],
    Phase-10a) inserts a direct-mapped write-through read cache in front of {!Cellram}
    ({!Icache}), serving PSRAM fetches/loads from on-chip distributed RAM (LUTRAM) on a
    hit. *)

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
  -> ?spi_slow_div_log2:int
  -> ?fast_mul:bool
  -> ?mul_stages:int
  -> ?icache:bool
  -> ?lines_log2:int
  -> ?write_update:bool
       (** Phase-10b cache snoop policy (default [false] = the proven Phase-10a
           snoop-invalidate): word store-hits update the cached line in place instead of
           dropping it — see {!Icache.create} *)
  -> ?video:bool
       (** sim-only A/B seam (default [true] = the board): [false] gates [vidreq], taking
           the video DMA off the PSRAM port — the framebuffer-in-BRAM counterfactual for
           the bench. NB holding the [pclk] {e input} low does not do this: in Cyclesim's
           one-domain sim the pclk raster advances 1:1 with [clk] regardless, so video is
           live in every board sim unless gated here. *)
  -> ?uart_baud_slow:int
  -> ?uart_baud_fast:int
  -> Signal.t I.t
  -> Signal.t O.t

(** [Soc] — the Phase-7 board variant of [Soc]: the same RISC5Top SoC, but with main
    memory behind the {!Cellram} PSRAM controller instead of the single-cycle BRAM [Ram].

    Differences from [Soc] (everything else — the MMIO map, peripherals, timer, video
    raster — is identical):
    - the core runs on a clock-enable ([ce]) driven by {!Cellram}, so it freezes during
      PSRAM wait-states (AGENT.md §3); its [stall_x] is tied off (video is arbitrated in
      {!Cellram}, not via the core's stall);
    - reads/writes of main memory, and the video framebuffer DMA, go through {!Cellram},
      which drives the external chip pins exposed here ([mem_adr]/[mem_dq_*]/[ram_*_n]).
      Boot-ROM fetches and MMIO accesses take the controller's on-chip fast path;
    - MMIO {e stores} take only that fast path — unlike [Soc], which faithfully also
      writes them into the aliased RAM word (soc.ml: "stores go to RAM unconditionally"),
      the board never sends an MMIO store to PSRAM. Benign (Oberon never reads the aliased
      top-64-B words back) and load-bearing for the one-pulse write strobes;
    - the framebuffer word is latched into [Video] on the controller's [vid_ack];
    - the ms-timer IRQ is {e stretched}: [RISC5.v] latches its interrupt capture every
      clock (even under stallX), but here the core's [irq1]/[int_pnd] flops are ce-gated,
      so a 1-clock tick landing in a frozen (ce=0) cycle would be lost. The board holds
      the request until a ce=1 cycle samples it — one edge per tick, and identical to
      [irq = limit] whenever the core is not frozen (so the lib [Soc] is unaffected).

    The chip itself is off-FPGA: in simulation a {!Cellram_model} is wired to these pins
    (the board boot checkpoint); on the board the Verilog top wires IOBUFs. The
    synthesizable design here holds no main-memory array.

    Parameters: [contents] is the boot-ROM image; every build knob — the timer, SPI and
    UART retunes for the board's clock, the PSRAM phase lengths, the multipliers, the
    cache, the framebuffer shadow, Halftone, the write buffer — arrives in one
    {!Build_config.t}, documented field by field there. *)

open Hardcaml

module I : sig
  type 'a t =
    { clock : 'a
    (** system / memory clock (the faithful rate is 25 MHz; the board's MMCM drives 60 MHz
        — the parameter defaults above assume 25, the board overrides) *)
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

(** [create ~contents c i] elaborates the board SoC in configuration [c] — the emitter
    passes {!Build_config.shipped}. *)
val create : contents:int array -> Build_config.t -> Signal.t I.t -> Signal.t O.t

(** Test scaffolding, not hardware (the {!Risc5.Ps2.For_tests} precedent): the board SoC
    closed with the behavioural {!Cellram_model} on its PSRAM pins, plus the idle-level
    driver — the one closure shared by the co-located tests and every test/board harness
    (board_tb: the boot checkpoint, the visual golden, bench_boot), so the input list and
    the idle levels live in exactly one place. *)
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
        (** [hsync]/[vsync]/[rgb] keep the whole video pixel path — the {!Framebuf} shadow
            BRAMs included — {e live} under Cyclesim's dead-code elimination: unobserved,
            the fetched-word path drives no output and is pruned, and a
            [lookup_mem_by_name "fb0".."fb3"] readback finds nothing. *)
        }
      [@@deriving hardcaml]
    end

    (** [create ~contents c i] closes {!Soc.create} in configuration [c] with the
        {!Cellram_model}. [?addr_bits] sizes the model: default [12] (a 4 KiB double — the
        co-located tests stay under byte 0x200; the video DMA aliases in it, unobserved);
        the boot gates pass [19], the full 1 MiB, to load the real disk.

        [?datasheet_chip] (default [false] = a chip that answers at once, so short phases
        exercise only the controller's control flow) holds the model, at [c]'s clock, to
        the datasheet's read access time and write pulse width and to the write access
        time the shipped configuration provides (62 ns; see {!Cellram_model.create}). *)
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

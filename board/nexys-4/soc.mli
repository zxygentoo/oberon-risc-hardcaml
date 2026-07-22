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

    Parameters (defaults are the faithful/sim values; the 60 MHz board build's overrides
    all live in emit_verilog.ml): [contents] is the boot-ROM image; [clocks_per_ms] the
    ms-timer prescaler (default 25000 = 1 ms at 25 MHz; the board passes 60000);
    [read_cycles]/[write_cycles] the PSRAM phase lengths (default {!Cellram}'s — 2, the
    sim/test value; the board synthesizes read 6 / write 5 = 100 / 83 ns at 60 MHz — see
    emit_verilog.ml); [spi_slow_div_log2] the SPI slow-divider depth (default 6 = clk÷64 =
    {!Spi}/[SPI.v]; the board passes 8 = clk÷256 to keep SD init ≤400 kHz at 60 MHz);
    [fast_mul]/[mul_stages] (defaults [false]/[0], Phase 9) swap the core's iterative
    multipliers for the DSP-backed, optionally pipelined {!Cpu.create} variants — see
    there (the board passes [true]/[2]); [icache] (default [false], Phase-10a) inserts a
    direct-mapped write-through read cache in front of {!Cellram} ({!Cache}), serving
    PSRAM fetches/loads from on-chip distributed RAM (LUTRAM) on a hit, sized by
    [lines_log2] (default 10 = 4 KiB) with the [write_update]/[video] knobs documented at
    the signature below; [uart_baud_slow]/[uart_baud_fast] the {!Uart_rx}/{!Uart_tx}
    divisors (defaults 1302/217, the faithful 25 MHz constants; the board passes 521/521 —
    both settings ~115200, see emit_verilog.ml). *)

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
           dropping it — see {!Cache.create}. Like [lines_log2], consulted only when
           [icache]. *)
  -> ?video:bool
       (** sim-only A/B seam (default [true] = the board): [false] gates [vidreq], taking
           the video DMA off the PSRAM port — the framebuffer-in-BRAM counterfactual for
           the bench. NB holding the [pclk] {e input} low does not do this: in Cyclesim's
           one-domain sim the pclk raster advances 1:1 with [clk] regardless, so video is
           live in every board sim unless gated here. *)
  -> ?fb_bram:bool
       (** Phase-10c (default [false] = the proven PSRAM video path): serve the video DMA
           from the {!Framebuf} BRAM shadow — a 1-cycle on-chip read — and tie
           {!Cellram}'s [vidreq] low, taking video off the PSRAM port entirely (the
           synthesizer then prunes the arbiter's video FSM and read-preemption logic). The
           shadow mirrors the same PSRAM-bound stores the cache snoops, so it equals the
           PSRAM framebuffer window at every instant — see {!Framebuf}. *)
  -> ?halftone:bool
       (** feat/halftone v2 (default [false]; requires [fb_bram] — enforced at
           elaboration): instantiate {!Halftone} — the generalized 8bpp display mode
           (client-uploaded tone LUT, threshold map, row map, scale registers, overlay
           rect). Its per-request [claim] (mode on AND the fetch word inside the client's
           rect) selects which shadow answers the video DMA: unclaimed = {!Framebuf} (the
           proven mono path, bit-identical to [halftone:false] while the control word is
           never written), claimed = the Halftone compose FSM. Also wires the
           vblank/frame-counter status word at MMIO slot 10 ([0xFFFFE8]). *)
  -> ?write_buffer:bool
       (** Phase-10d (default [false] = the proven synchronous write path): a 1-entry
           write buffer in {!Cellram} — a PSRAM store retires in one [ce] cycle and the
           write drains in the background; PSRAM reads wait out a pending drain
           (drain-before-read), so coherence is untouched. Pair with [fb_bram] on the
           board (without it a not-yet-drained framebuffer word could reach the raster a
           frame stale) — see {!Cellram.create}. *)
  -> ?wbuf_depth:int
       (** write-buffer FIFO depth 1..4 (default 1 = the proven Phase-10d slot); bursts up
           to the depth retire back-to-back — see {!Cellram.create}. Consulted only when
           [write_buffer]. *)
  -> ?uart_baud_slow:int
  -> ?uart_baud_fast:int
  -> Signal.t I.t
  -> Signal.t O.t

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

    (** [create ~contents i] closes {!Soc.create} with the {!Cellram_model}; the
        structural knobs forward. [?addr_bits] sizes the model: default [12] (a 4 KiB
        double — the co-located tests stay under byte 0x200; the video DMA aliases in it,
        unobserved); the boot gates pass [19], the full 1 MiB, to load the real disk. *)
    val create
      :  contents:int array
      -> ?clocks_per_ms:int
      -> ?read_cycles:int
      -> ?write_cycles:int
      -> ?icache:bool
      -> ?lines_log2:int
      -> ?write_update:bool
      -> ?video:bool
      -> ?fb_bram:bool
      -> ?halftone:bool
      -> ?write_buffer:bool
      -> ?wbuf_depth:int
      -> ?fast_mul:bool
      -> ?mul_stages:int
      -> ?addr_bits:int
      -> Signal.t I.t
      -> Signal.t O.t
  end

  (** drive every input to its idle level ([rst_n] excluded — reset sequencing belongs to
      the test). NB [pclk] low does not quiet the video DMA under Cyclesim's one-domain
      semantics; gate with {!Soc.create}'s [?video] if a test needs the bus alone. *)
  val drive_idle : Bits.t ref Tb.I.t -> unit
end

(** The RISC5Top peripheral/MMIO cluster — the faithful block both SoCs share.

    Millisecond timer, SPI master + [spiCtrl], UART (both directions) + [bitrate], PS/2
    keyboard, PS/2 mouse, switches/buttons + the LED latch, GPIO, and the MMIO read mux —
    everything RISC5Top.OStation.v hangs off its [iowadr] decode, in one instantiable
    block. Each SoC keeps its own address decode and hands this block the decoded bus
    (strobes + window + word); pad-side lines are driven directly.

    Extracted from the sim SoC so the board SoC stops hand-copying it. The board's
    departures are the explicit seams on {!create}; the block itself is never ce-gated
    (peripherals run at clock speed under a wait-stated CPU, as on real hardware). *)

open Hardcaml

(** The MMIO word map (RISC5Top's [iowadr] decode) — one exported name per word; the write
    strobes, writable registers and read-mux slots inside all share these, and an SoC's
    extra slots must avoid them. *)

val w_ms_timer : int
val w_switches_leds : int
val w_uart_data : int
val w_uart_status : int
val w_spi_data : int
val w_spi_ctrl : int
val w_mouse_kbd : int
val w_kbd_data : int
val w_gpio : int
val w_gpio_dir : int

module I : sig
  type 'a t =
    { clock : 'a
    ; rst_n : 'a (** active-low, synchronous — clears the RISC5Top-faithful subset *)
    ; wr : 'a (** the core's write strobe *)
    ; rd : 'a (** the core's read strobe *)
    ; ioenb : 'a (** the SoC's MMIO-window decode (top 64 B) *)
    ; iowadr : 'a (** the MMIO word address ([adr[5:2]]) *)
    ; outbus : 'a (** the core's store-data bus *)
    ; miso : 'a (** SPI: the already-ANDed SD/net line *)
    ; rxd : 'a (** RS-232 receive line; idles high *)
    ; btn : 'a (** buttons (RISC5Top [btn]); read-only via word 1 *)
    ; sw : 'a (** switches, logical/active-high (pad inversion is the shim's) *)
    ; gpio_in : 'a (** resolved GPIO pad inputs (RISC5Top [gpin]) *)
    ; ps2c : 'a (** PS/2 keyboard clock *)
    ; ps2d : 'a (** PS/2 keyboard data *)
    ; msclk : 'a (** PS/2 mouse clock — resolved open-drain line in *)
    ; msdat : 'a (** PS/2 mouse data — resolved open-drain line in *)
    }
  [@@deriving hardcaml]
end

module O : sig
  type 'a t =
    { io_data : 'a (** the MMIO read word for [iowadr] (mux into [inbus] on [ioenb]) *)
    ; ms_tick : 'a
    (** [limit] — a 1-clock pulse per millisecond. The sim SoC wires it straight to the
        core's [irq]; the board wraps it in its ce-domain IRQ stretch first. *)
    ; spi_ctrl : 'a
    (** the 4-bit [spiCtrl] register, exported for board-side derivations (RISC5Top's
        [SS]: [sd_cs = ~spi_ctrl[0]]) *)
    ; mouse_out : 'a (** the 28-bit mouse state word (the board's [mouse_dbg]) *)
    ; mosi : 'a
    ; sclk : 'a
    ; txd : 'a (** RS-232 transmit line; idles high *)
    ; leds : 'a (** RISC5Top [leds] = the [Lreg] latch *)
    ; gpio_out : 'a (** GPIO drive value (RISC5Top [gpout]; faithful no-reset) *)
    ; gpio_oe : 'a (** GPIO output-enable / direction (RISC5Top [gpoc]) *)
    ; msclk_oe : 'a (** mouse msclk open-drain: 1 = host pulls low (req-to-send) *)
    ; msdat_oe : 'a (** mouse msdat open-drain: 1 = host pulls low (command bit) *)
    }
  [@@deriving hardcaml]
end

(** [create i] builds the cluster.

    [?clocks_per_ms] (default [25000] = 1 ms at 25 MHz) is the timer prescaler; must fit
    the faithful 16-bit [cnt0] (enforced at elaboration). [?slow_div_log2] is
    {!Spi.create}'s divider-depth seam; [?baud_slow]/[?baud_fast] are the UART
    clock-scaling seams, passed to both directions together (they share the one [bitrate]
    bit). Defaults everywhere = the 25 MHz RISC5Top constants — the sim SoC passes
    nothing.

    [?extra_read_slots] maps SoC-specific read words (the board's Halftone status word at
    slot 10) into the otherwise-zero part of the 16-word window; a slot colliding with the
    faithful map, out of range, or not 32 bits wide fails at elaboration. Write-side
    extensions need no hook: an SoC derives its own strobe from
    [wr &: ioenb &: (iowadr ==:. word)] beside its extra logic. *)
val create
  :  ?clocks_per_ms:int
  -> ?slow_div_log2:int
  -> ?baud_slow:int
  -> ?baud_fast:int
  -> ?extra_read_slots:(int * Signal.t) list
  -> Signal.t I.t
  -> Signal.t O.t

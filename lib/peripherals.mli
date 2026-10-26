(** The peripheral cluster of RISC5Top, shared by both SoCs: the millisecond timer, the
    SPI master and its control register, the UART in both directions and its rate bit, the
    PS/2 keyboard and mouse, the switches, buttons and LED latch, GPIO, and the MMIO read
    mux — everything RISC5Top.OStation.v hangs off its [iowadr] decode. Each SoC does its
    own address decode and passes the decoded bus in.

    The block is never clock-gated: a CPU slowed by memory waits polls peripherals that
    run at full speed, as on any real machine. *)

open Hardcaml

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
    (** the timer's one-clock pulse per millisecond, for the core's [irq] *)
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

(** [?clocks_per_ms] (default 25000, 1 ms at 25 MHz) is the timer's prescaler and must fit
    the 16-bit [cnt0]. [?slow_div_log2] is {!Spi.create}'s; [?baud_slow] and [?baud_fast]
    are the UARTs', passed to both directions. The defaults are RISC5Top's constants for
    25 MHz.

    [?extra_read_slots] maps a SoC's own read words into the unused part of the 16-word
    window. A slot that collides with the cluster's map or with another extra slot, lies
    outside the window, or is not 32 bits wide fails at elaboration. Writes need no hook:
    a SoC derives its own strobe, [wr &: ioenb &: (iowadr ==:. word)]. *)
val create
  :  ?clocks_per_ms:int
  -> ?slow_div_log2:int
  -> ?baud_slow:int
  -> ?baud_fast:int
  -> ?extra_read_slots:(int * Signal.t) list
  -> Signal.t I.t
  -> Signal.t O.t

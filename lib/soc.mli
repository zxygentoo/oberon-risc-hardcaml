(** SoC top — the RISC5 core wired to the boot ROM ([Prom]), main memory ([Sram]) and the
    peripherals, reproducing RISC5Top's address decode and MMIO map. This is the Phase-6b
    integration target, and the design the boot-handoff checkpoint (AGENT.md §6) runs on
    the plain Cyclesim interpreter, where [lookup_reg]/[lookup_mem] reach this state
    directly.

    {1 Address decode}

    Three regions, exactly as RISC5Top splits them:

    - {b fetch}: [codebus = adr[23:14] = 0x3FF ? rom : ram] — the top 16 KiB decodes to
      the boot ROM, the rest to RAM.
    - {b load}: [inbus = adr[23:6] = 0x3FFFF ? io : ram] — the top 64 B is the MMIO
      window.
    - {b store}: [Sram] takes the core's write port directly. The SRAM has no [ioenb]
      gate, so it aliases MMIO/ROM-region stores harmlessly (the lockstep filters those by
      address).

    {1 Video, timer, interrupts}

    The video controller ({!Vid}) drives the core's [stall_x]: a DMA request steals one
    SRAM cycle every 32 px ([sram_adr = vidreq ? vidadr : adr]) to read the framebuffer,
    which scans out on [hsync]/[vsync]/[rgb] off the pixel clock [pclk].

    [irq] and the millisecond counter come from a free-running timer: a
    [clocks_per_ms]-cycle prescaler raises [limit] (the IRQ source), which ticks [cnt1],
    read at MMIO word 0.

    {1 MMIO map}

    Within the load window above (RISC5Top words 0–15):

    - {b 0} — millisecond counter ([cnt1]).
    - {b 1} — read [{btn, sw}] (buttons/switches, logical/active-high; default 0 = all-off
      = disk boot); a store latches the LEDs ([leds]).
    - {b 2/3} — UART ({!Rs232r}/{!Rs232t}): word 2 reads / transmits a byte on
      [rxd]/[txd]; word 3 carries the [{rdyTx, rdyRx}] status and the 1-bit [bitrate]
      select.
    - {b 4/5} — {!Spi} master (the one peripheral boot needs): word 4 = data (read =
      received, write = start a transfer), word 5 = control (write [fast]/slave-select,
      read = [rdy]). [miso] is an input and [mosi]/[sclk] are outputs (the SD card is
      driven test-side).
    - {b 6/7} — PS/2 keyboard + mouse ({!Ps2}/{!Mouse}): word 6 =
      [{keyboard-ready, mouse state}], word 7 = the keyboard byte (a read pops the FIFO).
      The mouse's open-drain [msclk]/[msdat] split into resolved-line inputs and drive-low
      [msclk_oe]/[msdat_oe] outputs.
    - {b 8/9} — GPIO: [gpio_out]/[gpio_oe] drive the split bidirectional pads
      ([gpout]/[gpoc]) and [gpio_in] reads them back.
    - {b 10–15} — unmapped (read 0).

    {1 Parameters}

    [~contents] is the boot ROM image (keeping the design library free of [prom.mem]);
    [~clocks_per_ms] defaults to 25000 — 1 ms at 25 MHz. *)

open Hardcaml

module I : sig
  type 'a t =
    { clock : 'a (** system clock (the 25 MHz core/memory domain) *)
    ; rst_n : 'a (** active-low reset (the core's [rst]) *)
    ; miso : 'a (** SPI master-in slave-out — the already-ANDed SD/net line *)
    ; rxd : 'a (** RS-232 receive line; idles high *)
    ; btn : 'a (** buttons (RISC5Top [btn]); read-only via MMIO word 1 *)
    ; sw : 'a (** switches, logical/active-high (RISC5Top's [~nswi], de-inverted) *)
    ; gpio_in : 'a (** resolved GPIO pad inputs (RISC5Top [gpin]) *)
    ; pclk : 'a (** 65 MHz pixel clock for {!Vid} (DCM/MMCM; a Phase-7 board input) *)
    ; ps2c : 'a (** PS/2 keyboard clock *)
    ; ps2d : 'a (** PS/2 keyboard data *)
    ; msclk : 'a (** PS/2 mouse clock — resolved open-drain line in *)
    ; msdat : 'a (** PS/2 mouse data — resolved open-drain line in *)
    }
  [@@deriving hardcaml]
end

module O : sig
  type 'a t =
    { adr : 'a (** 24-bit core byte address (fetch, or the load/store data address) *)
    ; rd : 'a (** core read strobe (load cycle) *)
    ; wr : 'a (** core write strobe (store cycle) *)
    ; ben : 'a (** byte enable — byte vs word access *)
    ; outbus : 'a (** store data (the core's write bus) *)
    ; codebus : 'a (** instruction-fetch read data — ROM or RAM, per the fetch decode *)
    ; inbus : 'a (** load read data — MMIO or RAM, per the load decode *)
    ; mosi : 'a (** SPI master-out slave-in *)
    ; sclk : 'a (** SPI serial clock *)
    ; txd : 'a (** RS-232 transmit line; idles high *)
    ; leds : 'a (** the 8 LEDs (RISC5Top [leds] = the [Lreg] latch, word 1) *)
    ; gpio_out : 'a (** GPIO drive value (RISC5Top [gpout], word 8) *)
    ; gpio_oe : 'a (** GPIO output-enable / direction (RISC5Top [gpoc], word 9) *)
    ; hsync : 'a (** VGA horizontal sync (active low) *)
    ; vsync : 'a (** VGA vertical sync (active low) *)
    ; rgb : 'a (** 1 bpp pixel replicated across the 6 RGB pins *)
    ; msclk_oe : 'a (** mouse [msclk] open-drain: 1 = host pulls low (request-to-send) *)
    ; msdat_oe : 'a (** mouse [msdat] open-drain: 1 = host pulls low (command bit) *)
    }
  [@@deriving hardcaml]
end

val create : contents:int array -> ?clocks_per_ms:int -> Signal.t I.t -> Signal.t O.t

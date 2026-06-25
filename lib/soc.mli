(** SoC top — the RISC5 core wired to the boot ROM ([Prom]), main memory ([Sram]) and the
    peripherals through RISC5Top's address decode:

    - fetch: [codebus = adr[23:14] = 0x3FF ? rom : ram] (top 16 KiB decodes to the boot
      ROM)
    - load: [inbus  = adr[23:6] = 0x3FFFF ? io : ram] (top 64 B is the MMIO window)
    - store: [Sram] takes the core's write port directly — the SRAM has no [ioenb] gate,
      so it aliases MMIO/ROM-region stores harmlessly (the lockstep filters those by
      address).

    The video controller ({!Vid}) drives the core's [stall_x]: a DMA request steals one
    SRAM cycle every 32 px ([sram_adr = vidreq ? vidadr : adr]) to read the framebuffer,
    which scans out on [hsync]/[vsync]/[rgb] off the pixel clock [pclk]. [irq] and the
    millisecond counter come from a free-running timer: a [clocks_per_ms]-cycle prescaler
    raises [limit] (the IRQ source) which ticks [cnt1], readable at MMIO word 0. The
    {!Spi} master — the one peripheral boot needs — sits at MMIO words 4 (data: read =
    received, write = start a transfer) and 5 (control: write [fast]/slave-select, read =
    [rdy]); its [miso] pin is an input and [mosi]/[sclk] are outputs (the SD card is
    driven test-side). UART ({!Rs232r}/{!Rs232t}, words 2/3) reads/transmits a byte on
    [rxd]/[txd], with [{rdyTx, rdyRx}] status and the 1-bit [bitrate] select at word 3.
    Word 1 reads the buttons/switches ([{btn, sw}], logical/active-high; default 0 =
    all-off = disk boot) and a store there latches the LEDs ([leds]). GPIO is words 8/9:
    [gpio_out] / [gpio_oe] drive the split bidirectional pads ([gpout]/[gpoc]) and
    [gpio_in] reads them back. PS/2 keyboard + mouse ({!Ps2}/{!Mouse}) are words 6/7: word
    6 = [{keyboard-ready, mouse state}], word 7 = the keyboard byte (a read pops the
    FIFO); the mouse's open-drain [msclk]/[msdat] split into resolved-line inputs and
    drive-low [msclk_oe]/[msdat_oe] outputs. That completes RISC5Top's MMIO map (words
    0-9); words 10-15 are unmapped (read 0). The boot-handoff checkpoint runs on the plain
    Cyclesim interpreter, where lookup_reg/lookup_mem reach this state directly.
    [~clocks_per_ms] defaults to 25000 (1 ms at 25 MHz); the boot ROM image is a
    [~contents] parameter, keeping the design library free of [prom.mem]. *)

open Hardcaml

module I : sig
  type 'a t =
    { clock : 'a
    ; rst_n : 'a
    ; miso : 'a
    ; rxd : 'a
    ; btn : 'a
    ; sw : 'a
    ; gpio_in : 'a
    ; pclk : 'a
    ; ps2c : 'a
    ; ps2d : 'a
    ; msclk : 'a
    ; msdat : 'a
    }
  [@@deriving hardcaml]
end

module O : sig
  type 'a t =
    { adr : 'a
    ; rd : 'a
    ; wr : 'a
    ; ben : 'a
    ; outbus : 'a
    ; codebus : 'a
    ; inbus : 'a
    ; mosi : 'a
    ; sclk : 'a
    ; txd : 'a
    ; leds : 'a
    ; gpio_out : 'a
    ; gpio_oe : 'a
    ; hsync : 'a
    ; vsync : 'a
    ; rgb : 'a
    ; msclk_oe : 'a
    ; msdat_oe : 'a
    }
  [@@deriving hardcaml]
end

val create : contents:int array -> ?clocks_per_ms:int -> Signal.t I.t -> Signal.t O.t

(** Minimal Phase-5 SoC — the RISC5 core wired to the boot ROM ([Prom]) and main memory
    ([Sram]) through RISC5Top's address decode:

    - fetch: [codebus = adr[23:14] = 0x3FF ? rom : ram] (top 16 KiB decodes to the boot
      ROM)
    - load: [inbus  = adr[23:6] = 0x3FFFF ? io : ram] (top 64 B is the MMIO window)
    - store: [Sram] takes the core's write port directly — the SRAM has no [ioenb] gate,
      so it aliases MMIO/ROM-region stores harmlessly (the lockstep filters those by
      address).

    [stall_x] is tied low (no video DMA until Phase 6). [irq] and the millisecond counter
    come from a free-running timer: a [clocks_per_ms]-cycle prescaler raises [limit] (the
    IRQ source) which ticks [cnt1], readable at MMIO word 0. The {!Spi} master — the one
    peripheral boot needs — sits at MMIO words 4 (data: read = received, write = start a
    transfer) and 5 (control: write [fast]/slave-select, read = [rdy]); its [miso] pin is
    an input and [mosi]/[sclk] are outputs (the SD card is driven test-side). Word 1 reads
    the buttons/switches ([{btn, sw}], logical/active-high; default 0 = all-off = disk
    boot) and a store there latches the LEDs ([leds]); the remaining unwired words read 0
    (the rest of the MMIO map is Phase 6b, in progress). The boot-handoff checkpoint runs
    on the plain Cyclesim interpreter, where lookup_reg/lookup_mem reach this state
    directly. [~clocks_per_ms] defaults to 25000 (1 ms at 25 MHz); the boot ROM image is a
    [~contents] parameter, keeping the design library free of [prom.mem]. *)

open Hardcaml

module I : sig
  type 'a t =
    { clock : 'a
    ; rst_n : 'a
    ; miso : 'a
    ; btn : 'a
    ; sw : 'a
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
    ; leds : 'a
    }
  [@@deriving hardcaml]
end

val create : contents:int array -> ?clocks_per_ms:int -> Signal.t I.t -> Signal.t O.t

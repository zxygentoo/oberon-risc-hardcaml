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
    IRQ source) which ticks [cnt1], readable at MMIO word 0; the other MMIO words read 0
    (peripherals are Phase 6). Architectural state-as-outputs for the hardcaml_c boot
    lockstep comes next (5.2c). [~clocks_per_ms] defaults to 25000 (1 ms at 25 MHz); the
    boot ROM image is a [~contents] parameter, keeping the design library free of
    [prom.mem]. *)

open Hardcaml

module I : sig
  type 'a t =
    { clock : 'a
    ; rst_n : 'a
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
    }
  [@@deriving hardcaml]
end

val create : contents:int array -> ?clocks_per_ms:int -> Signal.t I.t -> Signal.t O.t

(** Minimal Phase-5 SoC — the RISC5 core wired to the boot ROM ([Prom]) and main memory
    ([Sram]) through RISC5Top's address decode:

    - fetch: [codebus = adr[23:14] = 0x3FF ? rom : ram] (top 16 KiB decodes to the boot
      ROM)
    - load: [inbus  = adr[23:6] = 0x3FFFF ? io : ram] (top 64 B is the MMIO window)
    - store: [Sram] takes the core's write port directly — the SRAM has no [ioenb] gate, so
      it aliases MMIO/ROM-region stores harmlessly (the lockstep filters those by
      address).

    This is the skeleton. [irq] and [stall_x] are tied low and the MMIO read mux is a stub
    (reads 0): the millisecond timer + IO read mux arrive next (5.2b), and architectural
    state-as-outputs for the hardcaml_c boot lockstep after that (5.2c). The boot ROM
    image is a [~contents] parameter so the design library stays free of [prom.mem]. *)

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

val create : contents:int array -> Signal.t I.t -> Signal.t O.t

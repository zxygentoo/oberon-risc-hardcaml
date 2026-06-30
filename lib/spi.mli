(** Motorola SPI master — a faithful port of [SPI.v].

    One 32-bit shift register serves two modes, selected by [fast]:
    - {b slow} (clk÷2[{^[slow_div_log2]}], default ÷64 ≈ 390.6 kHz at 25 MHz): 8-bit
      bytes, MSbit first — the rate SD-card initialisation requires (must be ≤400 kHz);
    - {b fast} (clk÷3, ~8.33 MHz at 25 MHz): 32-bit words, LSByte first (each byte still
      MSbit first).

    A write of [data_tx] with [start] high begins a transfer; [rdy] drops to 0 for the
    duration and returns to 1 when the byte/word has shifted through, at which point
    [data_rx] holds the received data (the full register in fast mode, the low byte
    zero-extended in slow mode). [mosi]/[sclk] are derived from the shift register and a
    clock-divider counter; [miso] is sampled at each bit boundary. Idle line state:
    [mosi]=1, [sclk]=0. *)

open Hardcaml

module I : sig
  type 'a t =
    { clock : 'a (** system clock *)
    ; rst_n : 'a
    (** active-low, synchronous (woven into next-state, like [SPI.v]'s [~rst]) *)
    ; start : 'a (** one-cycle pulse: latch [data_tx] and begin a transfer *)
    ; fast : 'a (** mode: 1 = word/clk÷3, 0 = byte/clk÷64 *)
    ; data_tx : 'a (** transmit data, latched on [start] (low byte only in slow mode) *)
    ; miso : 'a (** master-in slave-out: sampled at each bit boundary *)
    }
  [@@deriving hardcaml]
end

module O : sig
  type 'a t =
    { data_rx : 'a
    (** received data: the full word in fast mode, the low byte zero-extended in slow *)
    ; rdy : 'a (** 1 = idle/done, 0 = transfer in flight *)
    ; mosi : 'a (** master-out slave-in (idle line = 1) *)
    ; sclk : 'a (** serial clock (idle line = 0) *)
    }
  [@@deriving hardcaml]
end

(** [create ?slow_div_log2 i] builds the SPI master, cycle-accurate to [SPI.v]: the
    clock-divider [tick], the bit counter [bitcnt], the [rdy] handshake, and the
    byte-interleaved shift permutation that realises fast/LSByte-first word order.

    [slow_div_log2] (default 6) is the slow-divider depth: the slow [sclk] is clk÷2[{^n}].
    6 reproduces [SPI.v] bit-for-bit (the @formal / cosim baseline); the Nexys-4 board
    overrides it to 7 (clk÷128) to hold the SD-init clock ≤400 kHz at a 50 MHz system
    clock. FAST is fixed at clk÷3 regardless. *)
val create : ?slow_div_log2:int -> Signal.t I.t -> Signal.t O.t

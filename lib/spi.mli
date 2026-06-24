(** Motorola SPI master — a faithful port of [SPI.v].

    One 32-bit shift register serves two modes, selected by [fast]:
    - {b slow} (clk÷64, ~400 kHz at 25 MHz): 8-bit bytes, MSbit first — the rate SD-card
      initialisation requires;
    - {b fast} (clk÷3, ~8.33 MHz): 32-bit words, LSByte first (each byte still MSbit
      first).

    A write of [data_tx] with [start] high begins a transfer; [rdy] drops to 0 for the
    duration and returns to 1 when the byte/word has shifted through, at which point
    [data_rx] holds the received data (the full register in fast mode, the low byte
    zero-extended in slow mode). [mosi]/[sclk] are derived from the shift register and a
    clock-divider counter; [miso] is sampled at each bit boundary. Idle line state:
    [mosi]=1, [sclk]=0. *)

open Hardcaml

module I : sig
  type 'a t =
    { clock : 'a
    ; rst_n :
        'a (* active-low, synchronous (woven into next-state, like [SPI.v]'s [~rst]) *)
    ; start : 'a (* one-cycle pulse: latch [data_tx] and begin a transfer *)
    ; fast : 'a (* mode: 1 = word/clk÷3, 0 = byte/clk÷64 *)
    ; data_tx : 'a
    ; miso : 'a
    }
  [@@deriving hardcaml]
end

module O : sig
  type 'a t =
    { data_rx : 'a
    ; rdy : 'a (* 1 = idle/done, 0 = transfer in flight *)
    ; mosi : 'a
    ; sclk : 'a
    }
  [@@deriving hardcaml]
end

(** [create i] builds the SPI master, cycle-accurate to [SPI.v]: the clock-divider [tick],
    the bit counter [bitcnt], the [rdy] handshake, and the byte-interleaved shift
    permutation that realises fast/LSByte-first word order. *)
val create : Signal.t I.t -> Signal.t O.t

(** SPI master, a port of [SPI.v].

    One 32-bit shift register serves two rates, selected by [fast]:
    - slow, clk / 2^[slow_div_log2] (clk/64 by default, 390.6 kHz at 25 MHz): 8-bit
      transfers, most significant bit first — the rate SD-card initialisation needs, which
      must not exceed 400 kHz;
    - fast, clk/3: 32-bit words, least significant byte first, each byte still most
      significant bit first.

    A pulse on [start] latches [data_tx] and begins a transfer. [rdy] is low for its
    duration; when it returns, [data_rx] holds what was received (the whole register in
    fast mode, the low byte in slow mode). [miso] is sampled at each bit boundary. Idle:
    [mosi] = 1, [sclk] = 0. *)

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

(** [slow_div_log2] (default 6, [SPI.v]'s clk/64, which is what the proof and the co-
    simulation check) is the depth of the slow divider. A design on a faster clock raises
    it so that card initialisation stays under 400 kHz. The fast rate is clk/3 whatever it
    is. *)
val create : ?slow_div_log2:int -> Signal.t I.t -> Signal.t O.t

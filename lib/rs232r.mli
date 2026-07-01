(** RS232 receiver — a faithful port of [RS232R.v].

    Recovers one byte from the asynchronous serial line [rxd]: a 2-FF synchronizer
    ([Q0]/[Q1]) samples [rxd] into the clock domain and detects the start bit's falling
    edge ([Q1 & ~Q0]); from there a baud divider ([tick]) times nine bit-windows and the
    line is sampled at each window's {b centre} ([midtick], [tick = limit/2]) for maximum
    noise margin — the start bit, then 8 data bits LSbit-first, shifted into [shreg].
    [rdy] rises when the byte is complete; software reads [data] and pulses [done_] to
    clear [rdy]. [fsel] picks the baud rate (0 = 19200, 1 = 115200, at a 25 MHz clock). *)

open Hardcaml

module I : sig
  type 'a t =
    { clock : 'a (** system clock *)
    ; rst_n : 'a
    (** active-low, synchronous (woven into next-state, like [RS232R.v]'s [~rst]) *)
    ; rxd : 'a (** the asynchronous serial input line; idles high *)
    ; fsel : 'a (** baud select: 0 = 19200, 1 = 115200 (at 25 MHz) *)
    ; done_ : 'a
    (** one-cycle pulse: "byte has been read", clears [rdy] ([done] is a keyword) *)
    }
  [@@deriving hardcaml]
end

module O : sig
  type 'a t =
    { rdy : 'a (** 1 = a received byte is available in [data] *)
    ; data : 'a (** the received byte (valid while [rdy]) *)
    }
  [@@deriving hardcaml]
end

(** [create i] builds the receiver, cycle-accurate to [RS232R.v]: the [Q0]/[Q1]
    synchronizer and start-edge detector, the [tick] baud divider, mid-bit sampling at
    [midtick], and the [run]/[stat] framing of the nine-window receive.

    [?baud_slow]/[?baud_fast] are the bit-window lengths in clocks for the two [fsel]
    rates (default [1302]/[217] = [RS232R.v]'s 19200/115200 at 25 MHz). They scale with
    the system clock so the wire stays at a standard baud — the board passes clock-matched
    values (e.g. 60 MHz ⇒ [3125]/[521] for exact 19200 / ~115200); the default keeps the
    faithful, Phase-8-proven 25 MHz unit. Must fit the 12-bit [tick] (< 4096). *)
val create : ?baud_slow:int -> ?baud_fast:int -> Signal.t I.t -> Signal.t O.t

(** RS-232 transmitter, a port of [RS232T.v].

    It sends one byte as a 10-bit frame on [txd]: a start bit (0), the eight data bits
    least significant first, a stop bit (1). The line idles high. [fsel] selects one of
    two rates: clk/1302 or clk/217 in the RTL, which are 19200 and 115200 baud at 25 MHz.

    Pulse [start] for one cycle with [data] valid while [rdy] is high. [rdy] is low for
    the frame's ten bit times; software polls it before sending the next byte. *)

open Hardcaml

module I : sig
  type 'a t =
    { clock : 'a (** system clock *)
    ; rst_n : 'a
    (** active-low, synchronous (woven into next-state, like [RS232T.v]'s [~rst]) *)
    ; start : 'a (** one-cycle pulse: latch [data] and begin a frame *)
    ; fsel : 'a (** baud select: 0 = 19200, 1 = 115200 (at 25 MHz) *)
    ; data : 'a (** the byte to transmit (valid at [start]) *)
    }
  [@@deriving hardcaml]
end

module O : sig
  type 'a t =
    { rdy : 'a (** 1 = idle/ready, 0 = frame in flight *)
    ; txd : 'a (** the serial line; idles high *)
    }
  [@@deriving hardcaml]
end

(** [?baud_slow] and [?baud_fast] are the divider limits for the two settings of [fsel] (a
    bit lasts limit + 1 clocks), defaulting to the RTL's. A design on another clock passes
    its own, so that the line keeps a standard rate. They must equal the receiver's
    ({!Uart_rx.create}) and lie in 1..4095, which is checked at elaboration. *)
val create : ?baud_slow:int -> ?baud_fast:int -> Signal.t I.t -> Signal.t O.t

(** [RS232T.v]'s constants for 25 MHz: 1302 (19200 baud) and 217 (115200).
    {!Uart_rx.create} has the same defaults; one rate-select bit drives both directions. *)
val default_baud_slow : int

val default_baud_fast : int

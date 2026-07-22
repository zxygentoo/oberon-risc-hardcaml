(** RS232 transmitter — a faithful port of [RS232T.v].

    Serialises one byte as a 10-bit UART frame on [txd]: a start bit (0), the 8 data bits
    LSbit-first, then a stop bit (1); the line idles high. [fsel] picks 19200 baud
    (clk/1302) or 115200 (clk/217), at a 25 MHz clock.

    Pulse [start] for one cycle with [data] valid while [rdy] is high to begin a frame;
    [rdy] drops to 0 for the ~10 bit-times of the frame and returns to 1 when the
    transmitter is idle again (software polls [rdy] before sending the next byte). *)

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

(** [create i] builds the transmitter, cycle-accurate to [RS232T.v]: the [tick] baud
    divider, the [bitcnt] frame counter, the [run]/[rdy] handshake, and the 9-bit shift
    register whose implicit framing emits start/data/stop.

    [?baud_slow]/[?baud_fast] are the bit-window lengths in clocks for the two [fsel]
    rates (default {!default_baud_slow}/{!default_baud_fast}); the 60 MHz board passes

    [521]/[521] (both settings ~115200; see emit_verilog.ml) so the wire stays at a
    standard baud. Must match the receiver ({!Uart_rx.create}) and fit the 12-bit [tick]
    (< 4096; enforced at elaboration). *)
val create : ?baud_slow:int -> ?baud_fast:int -> Signal.t I.t -> Signal.t O.t

(** [RS232T.v]'s 25 MHz constants — [1302] (19200 baud) and [217] (115200).
    {!Uart_rx.create} defaults to the same pair: the SoC's single [bitrate] bit drives
    both directions, so the defaults must stay equal. *)
val default_baud_slow : int

val default_baud_fast : int

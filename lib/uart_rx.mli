(** RS-232 receiver, a port of [RS232R.v].

    It recovers one byte from the asynchronous line [rxd]. Two flip-flops ([Q0], [Q1])
    bring [rxd] into the clock domain and detect the falling edge of the start bit. From
    there a divider times nine bit windows, and the line is sampled at the centre of each,
    as far as possible from both of its edges: the start bit, then eight data bits, least
    significant first. [rdy] rises when the byte is complete; software reads [data] and
    pulses [done_] to clear it. [fsel] selects the rate, as in {!Uart_tx}. *)

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

(** [?baud_slow] and [?baud_fast] are the divider limits for the two settings of [fsel],
    with {!Uart_tx}'s defaults and constraints; see {!Uart_tx.create}. The line is sampled
    at half the limit. *)
val create : ?baud_slow:int -> ?baud_fast:int -> Signal.t I.t -> Signal.t O.t

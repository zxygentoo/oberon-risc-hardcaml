(** PS/2 keyboard receiver, a port of [PS2.v].

    The keyboard drives both the clock [ps2c] (10 to 16 kHz) and the data [ps2d]. Two
    flip-flops synchronise [ps2c] and detect each of its falling edges, on which [ps2d] is
    shifted into an 11-bit register. The register is reset to all ones, and the frame's
    start bit, a 0, walks down it over the eleven bits (start, eight data bits least
    significant first, parity, stop); its arrival at bit 0 marks the frame complete. Each
    byte goes into a 16-byte FIFO: [rdy] says the FIFO is not empty, [data] is its head,
    and a pulse on [done_] pops it. *)

open Hardcaml

module I : sig
  type 'a t =
    { clock : 'a (** system clock *)
    ; rst_n : 'a
    (** active-low, synchronous (woven into next-state, like [PS2.v]'s [~rst]) *)
    ; done_ : 'a
    (** one-cycle pulse: "byte has been read", pops the FIFO ([done] is a keyword) *)
    ; ps2c : 'a (** PS/2 clock from the keyboard (asynchronous) *)
    ; ps2d : 'a (** PS/2 data from the keyboard *)
    }
  [@@deriving hardcaml]
end

module O : sig
  type 'a t =
    { rdy : 'a (** 1 = a byte is available in [data] (FIFO non-empty) *)
    ; shift : 'a (** the recovered bit strobe ([ps2c] falling edge); unused at the SoC *)
    ; data : 'a (** the FIFO head byte (valid while [rdy]) *)
    }
  [@@deriving hardcaml]
end

val create : Signal.t I.t -> Signal.t O.t

(** Test scaffolding, not hardware: the device's side of a PS/2 frame, for every testbench
    that plays a PS/2 device. *)
module For_tests : sig
  (** odd parity over the 8 data bits *)
  val odd_parity : int -> int

  (** the 11 frame bits in wire order: start (0), 8 data LSbit-first, odd parity, stop (1) *)
  val frame_bits : int -> bool list
end

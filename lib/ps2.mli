(** PS/2 keyboard receiver — a faithful port of [PS2.v].

    The keyboard drives both a clock [ps2c] (~10-16 kHz) and data [ps2d]; this module
    recovers bytes from that device-clocked serial stream. A 2-FF synchronizer detects
    each falling edge of [ps2c] ([shift]) and samples [ps2d] into an 11-bit shift
    register; the start bit (0), against an all-1s reset, walks down to bit 0 over the
    frame's 11 bits (start, 8 data LSbit-first, parity, stop), self-timing frame
    completion. Each completed byte ([shreg[8:1]]) is pushed into a 16-byte FIFO; [rdy] =
    FIFO non-empty, [data] = its head, and a read pulse [done_] pops it. *)

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

(** [create i] builds the keyboard receiver, cycle-accurate to [PS2.v]: the [Q0]/[Q1]
    synchronizer + [shift] edge detect, the walking-start-bit 11-bit frame assembly, and
    the 16-byte FIFO (an inferred RAM, async-read like the register file). *)
val create : Signal.t I.t -> Signal.t O.t

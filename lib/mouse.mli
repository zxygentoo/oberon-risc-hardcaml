(** PS/2 mouse, a port of [MousePM.v].

    A bidirectional PS/2 mouse with the IntelliMouse initialisation that enables the wheel
    and the third button. Two phases, sequenced by [sent] (0..7), with
    [run = (sent == 7)]:
    - initialisation ([run] = 0): the host sends seven commands (set sample rate 200, 100,
      80, and enable). For each it requests to send by pulling [msclk] low for about 1.1
      ms, releases it, and shifts the 9-bit command out on [msdat] while the device
      supplies the clock;
    - reports ([run] = 1): the device sends 33-bit movement packets; the module assembles
      each, with a walking start bit as in [PS2.v], and accumulates [x], [y] and the
      buttons.

    [msclk] and [msdat] are open-drain and bidirectional in the RTL. Hardcaml has no
    inout, so each is split into an output that pulls the line low ([msclk_oe],
    [msdat_oe]) and an input carrying the resolved line; the pad, or the testbench, does
    the wired-AND. *)

open Hardcaml

module I : sig
  type 'a t =
    { clock : 'a (** system clock *)
    ; rst_n : 'a (** active-low reset (the RTL [rst]) *)
    ; msclk : 'a (** resolved PS/2 clock line, sampled by the module *)
    ; msdat : 'a (** resolved PS/2 data line *)
    }
  [@@deriving hardcaml]
end

module O : sig
  type 'a t =
    { msclk_oe : 'a
    (** open-drain: 1 = host pulls [msclk] low (request-to-send [req]); 0 = hi-Z *)
    ; msdat_oe : 'a
    (** open-drain: 1 = host pulls [msdat] low (command bit [~tx[0]]); 0 = hi-Z *)
    ; out : 'a
    (** [{run, btns[2:0], 2'b0, y[9:0], 2'b0, x[9:0]}] — mouse state read at MMIO word 6 *)
    }
  [@@deriving hardcaml]
end

val create : Signal.t I.t -> Signal.t O.t

(** Test scaffolding, not hardware (the {!Ps2.For_tests} precedent): the PS/2 mouse on the
    other end of the wire, shared by this module's device test and the RTL co-sim dumper
    so the two cannot drift apart. *)
module For_tests : sig
  module Device : sig
    type t

    (** [attach ?on_cycle sim] releases reset and takes over [sim]'s [msclk]/[msdat]
        inputs, resolving the open-drain lines before every clock. [on_cycle] runs after
        each clock with the device's own pull-lows — the co-sim dumper records its trace
        there. *)
    val attach
      :  ?on_cycle:(msclk_low:bool -> msdat_low:bool -> unit)
      -> (Bits.t ref I.t, Bits.t ref O.t) Cyclesim.t
      -> t

    (** clock the host's init commands through the request-to-send handshake until the
        port reports [run] *)
    val init : t -> unit

    (** stream one 3-byte movement packet and wait for the port to accumulate it *)
    val send_report : t -> status:int -> mx:int -> my:int -> unit

    (** the port's state word, by field *)
    val run : t -> bool

    val x : t -> int
    val y : t -> int
    val btns : t -> int
  end
end

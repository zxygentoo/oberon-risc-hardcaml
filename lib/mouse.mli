(** PS/2 mouse — a faithful port of [MousePM.v] (the [MouseP] module).

    A bidirectional PS/2 mouse with the Microsoft/IntelliMouse scroll-wheel init magic.
    Two phases, sequenced by [sent] (0..7) with [run = sent==7]:

    - INIT ([run]=0): the host transmits a 7-command sequence (set-sample-rate
      200/100/80 + enable) that unlocks the 3rd/scroll button. Each command needs a
      request-to-send: pull [msclk] low for ~1.1 ms ([req]), release, then clock the 9-bit
      command out on [msdat] while the device supplies the clock.
    - REPORT ([run]=1): the device streams 33-bit movement packets; the module assembles
      each frame (a walking start bit, as in [PS2.v]) and accumulates [x]+=dx, [y]+=dy,
      [btns].

    [msclk]/[msdat] are open-drain bidirectional in the RTL ([line = drive ? 0 : z]).
    Hardcaml has no inout, so each splits into a drive-low OUTPUT ([*_oe]) and the
    resolved wire-value INPUT; the pad (Phase 7) / testbench does the open-drain
    wired-AND. *)

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

(** [create i] builds the mouse, cycle-faithful to [MousePM.v]: the request-to-send [req]
    oscillator (count to ~1.1 ms), the [sent] init-command sequencer, the [msclk]-debounce
    [filter] + [shift] strobe, the walking-start-bit [rx]/[tx] frames, and the
    [x]/[y]/[btns] accumulation. The Verilator co-sim proves it bit-exact to [MousePM.v]. *)
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

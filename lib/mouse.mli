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
    { clock : 'a
    ; rst_n : 'a (* active-low reset (the RTL [rst]) *)
    ; msclk : 'a (* resolved PS/2 clock line, sampled by the module *)
    ; msdat : 'a (* resolved PS/2 data line *)
    }
  [@@deriving hardcaml]
end

module O : sig
  type 'a t =
    { msclk_oe :
        'a (* open-drain: 1 = host pulls msclk low (request-to-send [req]); 0 = hi-Z *)
    ; msdat_oe :
        'a (* open-drain: 1 = host pulls msdat low (command bit [~tx[0]]); 0 = hi-Z *)
    ; out : 'a (* {run, btns[2:0], 2'b0, y[9:0], 2'b0, x[9:0]} — mouse state at MMIO 6 *)
    }
  [@@deriving hardcaml]
end

(** [create i] builds the mouse, cycle-faithful to [MousePM.v]: the request-to-send [req]
    oscillator (count to ~1.1 ms), the [sent] init-command sequencer, the [msclk]-debounce
    [filter] + [shift] strobe, the walking-start-bit [rx]/[tx] frames, and the
    [x]/[y]/[btns] accumulation. The Verilator co-sim proves it bit-exact to [MousePM.v]. *)
val create : Signal.t I.t -> Signal.t O.t

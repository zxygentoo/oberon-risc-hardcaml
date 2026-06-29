(** [Cellram_model] — a behavioural model of the external cellular PSRAM, for
    {b simulation only} (it is never instantiated in the board design; the real chip is
    off-FPGA pins).

    Wired to {!Cellram}'s chip-side pins, it closes the loop in a Cyclesim testbench: an
    asynchronous (combinational) 16-bit read of the addressed halfword onto [mem_dq_i],
    and a per-byte synchronous write on the clock edge while [ce_n] and [we_n] are low
    (the lanes gated by [lb_n]/[ub_n]). Two 8-bit lanes share the halfword address (named
    [cram_lo] / [cram_hi]) so a byte store touches only its lane — the same shape as
    [Sram] (lib/). A 1 MB window (2^19 halfwords) starting zeroed; the controller's
    wait-state FSM runs unchanged around it, so sim exercises the real control flow
    against an instantly-responding chip. *)

open Hardcaml

module I : sig
  type 'a t =
    { clock : 'a
    ; mem_adr : 'a (** halfword address (only the low 19 bits index the window) *)
    ; mem_dq_o : 'a (** 16-bit write data from the controller *)
    ; ce_n : 'a
    ; we_n : 'a
    ; ub_n : 'a (** upper byte lane enable, active low *)
    ; lb_n : 'a (** lower byte lane enable, active low *)
    }
  [@@deriving hardcaml]
end

module O : sig
  type 'a t = { mem_dq_i : 'a (** 16-bit read data to the controller (combinational) *) }
  [@@deriving hardcaml]
end

val create : Signal.t I.t -> Signal.t O.t

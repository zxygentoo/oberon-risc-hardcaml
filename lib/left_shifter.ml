(** [Left_shifter] — combinational logical left shift; the RISC5 [LSL] datapath unit.

    Mirrors Oberon's [LeftShifter.v] port-for-port: [y = x << sc], zero-filled, with [sc]
    a 5-bit count (shift of 0..31). In the core it is fed operand [B] and [C1[4:0]] — the
    low 5 bits of the second operand (see [RISC5.v:57]).

    Wirth's RTL stages the shift radix-4 (the groups [sc[1:0]] / [sc[3:2]] / [sc[4]],
    three mux levels). We use Hardcaml's [log_shift] barrel-shifter combinator instead; it
    lowers to a radix-2 net (five 2:1-mux stages — shifts 1/2/4/8/16) — a different
    netlist but the identical combinational function, which synthesis re-maps onto the
    LUT6 fabric either way. Per AGENT.md §2: be idiomatic in the combinational datapath. *)

open Hardcaml
open Signal

(** Combinational core: [x] shifted logically left by [sc]. Handy to call inline from the
    ALU as well as through {!create}. *)
let shift ~x ~sc = log_shift ~f:sll x ~by:sc

module I = struct
  type 'a t =
    { x : 'a [@bits 32]
    ; sc : 'a [@bits 5]
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t = { y : 'a [@bits 32] } [@@deriving hardcaml]
end

let create (i : _ I.t) : _ O.t = { O.y = shift ~x:i.x ~sc:i.sc }

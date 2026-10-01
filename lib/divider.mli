(** Restoring division, the DIV unit: a port of [Divider.v]. It takes 33 cycles, with the
    same counter and stall as {!Multiplier}: [stall = run & ~(S == 33)], and [run] low
    clears [S].

    {1 The divisor must be positive}

    [y] must lie in 1 .. 2^31 - 1 (the RTL says [// y > 0]). The restoring step reads the
    top bit of a 32-bit trial difference as "the remainder is smaller than the divisor",
    which holds only while the partial remainder stays below 2^31. Nothing in the hardware
    enforces it: the Oberon compiler emits a trap for a divisor that is not positive.

    {1 Signedness: floored division}

    [u] here means {e signed}: the core passes the inverse of the instruction's u bit.
    Signed division divides [|x|] by [y] and then corrects to floored division, rounding
    toward minus infinity, with a remainder that is never negative: for [x < 0] the
    quotient is [-(|x|/y)] when the division is exact and [-(|x|/y) - 1] otherwise, and
    the remainder 0 or [y - (|x| mod y)] to match. The quotient is the instruction's
    result; the remainder goes to [H]. *)

open Hardcaml

module I : sig
  type 'a t =
    { clock : 'a (** clock; the state counter [S] advances on each rising edge *)
    ; run : 'a (** [DIV]/[DIV'] decoded — enable + synchronous clear for the counter *)
    ; u : 'a (** signed mode: 1 = signed (floored) division *)
    ; x : 'a (** 32-bit dividend (operand [B]) *)
    ; y : 'a (** 32-bit divisor (operand [C1]); must be [1 .. 2^31-1] *)
    }
  [@@deriving hardcaml]
end

module O : sig
  type 'a t =
    { stall : 'a (** high while [run] and [S<>33]; freezes the core's PC/IR *)
    ; quot : 'a (** 32-bit quotient → result [R.a] *)
    ; rem : 'a (** 32-bit remainder → [H] (non-negative for the floored result) *)
    }
  [@@deriving hardcaml]
end

(** [?ce] (default [vdd]) is the clock enable the core passes on. Held low it freezes the
    unit's state together with the core's, so that the counter cannot run past its end
    during a memory wait and start the division again. *)
val create : ?ce:Signal.t -> Signal.t I.t -> Signal.t O.t

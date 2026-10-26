(** Single-precision divide, the FDV unit: a port of [FPDivider.v]. A restoring divider
    forms the quotient of the two 24-bit mantissas in 26 cycles, and combinational logic
    around it handles the exponents, rounds and repacks.

    {1 Number format}

    IEEE-754 single precision, [{sign:1, exp:8 (bias 127), frac:23}], the leading 1
    implicit. A zero dividend ([xe = 0]) gives 0; a zero divisor ([ye = 0]) gives a signed
    infinity. The result's sign is [x[31] ^ y[31]] and its exponent
    [xe - ye + 126 + Q[25]]: subtracting the exponents cancels the bias, so it is added
    back, and [Q[25]] accounts for the normalising shift.

    {1 Timing}

    [run] is high while the core decodes FDV; it is the enable and the synchronous clear,
    and there is no reset. With [run] high [S] walks from 0 to 26: each of the cycles
    0..25 is one restoring step and yields one quotient bit, the first starting from [x]'s
    mantissa, and at 26 [stall] drops with [z] valid. So [stall = run & ~(S == 26)]. *)

open Hardcaml

module I : sig
  type 'a t =
    { clock : 'a (** clock; the state counter [S] advances on each rising edge *)
    ; run : 'a (** [FDV] decoded — enable + synchronous clear for the counter *)
    ; x : 'a (** 32-bit dividend (operand [B]) *)
    ; y : 'a (** the divisor, the register C0 (the FP units never take the immediate) *)
    }
  [@@deriving hardcaml]
end

module O : sig
  type 'a t =
    { stall : 'a (** high while [run] and [S<>26]; freezes the core's PC/IR *)
    ; z : 'a (** 32-bit result -> [R.a] *)
    }
  [@@deriving hardcaml]
end

(** [?ce] (default [vdd]) is the clock enable the core passes on; see {!Divider.create}. *)
val create : ?ce:Signal.t -> Signal.t I.t -> Signal.t O.t

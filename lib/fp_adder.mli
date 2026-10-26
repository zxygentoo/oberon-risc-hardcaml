(** Single-precision add and subtract, with the FLT and FLOOR conversions: a port of
    [FPAdder.v], a three-stage pipeline that aligns, adds and renormalises, holding the
    core with [stall] for three cycles.

    {1 Number format}

    IEEE-754 single precision, [{sign:1, exp:8 (bias 127), frac:23}], the leading 1
    implicit; zero is all bits 0, whatever the sign. Internally the mantissa carries the
    restored leading 1 and a guard bit below it for rounding.

    {1 Timing}

    [run] is high while the core decodes the operation. It is the enable and also the
    synchronous clear: while it is low the counter [State] stays at 0, and there is no
    reset. With [run] high [State] walks from 0 to 3: the three pipeline registers fill at
    the ends of states 0, 1 and 2, and at 3 [stall] drops with [z] valid. So
    [stall = run & ~(State == 3)].

    The operand signs, the result exponent and the zero flags are combinational in the
    {e current} [x] and [y], so both must be held for the whole run. The core does hold
    them: they are register-file outputs, and it is stalled.

    {1 Operation select}

    - [u = 0, v = 0]: FAD. FSB takes the same path; the core flips the sign of operand 2
      first.
    - [u = 1, v = 0]: FLT, integer to float: [x] is taken as an integer.
    - [u = 0, v = 1]: FLOOR, float to integer: the result is read from the aligned sum,
      without renormalising. *)

open Hardcaml

module I : sig
  type 'a t =
    { clock : 'a
    ; run : 'a (** op decoded — enable + synchronous clear for the [State] counter *)
    ; u : 'a (** [FLT] select (integer -> float) *)
    ; v : 'a (** [FLOOR] select (float -> integer) *)
    ; x : 'a (** 32-bit operand 1 (operand [B]) — a float, or an integer for [FLT] *)
    ; y : 'a
    (** operand 2, the register C0 (the FP units never take the immediate), its sign
        already flipped for FSB. For FLT and FLOOR the compiler supplies 0x4B000000 (2^23)
        here, which fixes the alignment. *)
    }
  [@@deriving hardcaml]
end

module O : sig
  type 'a t =
    { stall : 'a (** high while [run] and [State<>3]; freezes the core's PC/IR *)
    ; z : 'a (** 32-bit result -> [R.a] *)
    }
  [@@deriving hardcaml]
end

(** [?ce] (default [vdd]) is the clock enable the core passes on; see {!Divider.create}. *)
val create : ?ce:Signal.t -> Signal.t I.t -> Signal.t O.t

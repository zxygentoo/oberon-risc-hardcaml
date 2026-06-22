(** [Fp_multiplier] — iterative IEEE-754 single-precision multiply; the RISC5 [FML] unit.

    A faithful port of Oberon's [FPMultiplier.v]: a shift-and-add sequential multiplier
    that forms the 48-bit product of the two 24-bit mantissas over 25 cycles, then rounds,
    normalizes, and repacks it into a 32-bit float — holding the core with [stall] until
    its state counter reaches the terminal value. The mantissa engine is the {!Multiplier}
    idea in miniature (24 bits instead of 32); the floating-point work is the
    combinational exponent/round wrapper around it.

    {1 Number format}

    IEEE-754 single precision: [{sign:1, exp:8 (bias 127), frac:23}], value
    [(-1)^sign * 2^(exp-127) * 1.frac] with the leading [1.] implicit. A zero (or
    denormal) operand is detected by [exp = 0] and forces a zero result. The result sign
    is simply [x[31] ^ y[31]]; the result exponent is [xe + ye - 127], bumped by one when
    the mantissa product reaches [2.0].

    {1 Timing}
    (mirrored exactly from the RTL — AGENT.md §2)

    [run] is asserted by the core while [FML] is decoded, and doubles as enable {e and}
    synchronous clear: while [run] is low the 5-bit state counter [S] is pinned at 0, so
    the next multiply always begins from a clean load — there is no reset. Once [run]
    asserts, [S] walks 0->25: [S=0] loads [x]'s mantissa, [S=1..24] are the 24
    accumulate/shift iterations, and at [S=25] [stall] drops with [z] valid. Thus
    [stall = run & ~(S==25)], and the core keeps PC/IR frozen for the whole run. *)

open Hardcaml

module I : sig
  type 'a t =
    { clock : 'a
    ; run : 'a (** [FML] decoded — enable + synchronous clear for the counter *)
    ; x : 'a (** 32-bit operand 1 (operand [B]) *)
    ; y : 'a (** 32-bit operand 2 (operand [C1]) *)
    }
  [@@deriving hardcaml]
end

module O : sig
  type 'a t =
    { stall : 'a (** high while [run] and [S<>25]; freezes the core's PC/IR *)
    ; z : 'a (** 32-bit result -> [R.a] *)
    }
  [@@deriving hardcaml]
end

(** [create] is the [FML] unit as a Hardcaml [I]-to-[O] interface, for instantiation and
    simulation. *)
val create : Signal.t I.t -> Signal.t O.t

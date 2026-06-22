(** [Fp_divider] — iterative IEEE-754 single-precision divide; the RISC5 [FDV] unit.

    A faithful port of Oberon's [FPDivider.v]: a restoring-division sequential divider
    that forms the quotient of the two 24-bit mantissas over 26 cycles, then rounds,
    normalizes, and repacks it into a 32-bit float — holding the core with [stall] until
    its state counter reaches the terminal value. The dual of {!Fp_multiplier}: where the
    multiplier shifts and {e adds} to grow a product, the divider shifts and {e subtracts}
    to grow a quotient.

    {1 Number format}

    IEEE-754 single precision: [{sign:1, exp:8 (bias 127), frac:23}], value
    [(-1)^sign * 2^(exp-127) * 1.frac] with the leading [1.] implicit. A zero dividend
    ([xe = 0]) gives 0; a zero divisor ([ye = 0], divide-by-zero) gives a signed infinity.
    The result sign is [x[31] ^ y[31]]; the result exponent is [xe - ye + 126 + Q[25]] —
    subtracting the operand exponents cancels the bias, so it is re-added, with the
    normalization shift folded into the [+ Q[25]].

    {1 Timing}
    (mirrored exactly from the RTL — AGENT.md §2)

    [run] is asserted by the core while [FDV] is decoded, and doubles as enable {e and}
    synchronous clear: while [run] is low the 5-bit state counter [S] is pinned at 0, so
    the next divide always begins from a clean load — there is no reset. Once [run]
    asserts, [S] walks 0->26: [S=0] loads [x]'s mantissa, [S=1..25] are the
    restoring-division steps, and at [S=26] [stall] drops with [z] valid. Thus
    [stall = run & ~(S==26)], and the core keeps PC/IR frozen for the whole run. *)

open Hardcaml

module I : sig
  type 'a t =
    { clock : 'a
    ; run : 'a (** [FDV] decoded — enable + synchronous clear for the counter *)
    ; x : 'a (** 32-bit dividend (operand [B]) *)
    ; y : 'a (** 32-bit divisor (operand [C1]) *)
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

(** [create] is the [FDV] unit as a Hardcaml [I]-to-[O] interface, for instantiation and
    simulation. *)
val create : Signal.t I.t -> Signal.t O.t

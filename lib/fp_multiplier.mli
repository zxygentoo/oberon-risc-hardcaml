(** Single-precision multiply, the FML unit: a port of [FPMultiplier.v]. A shift-and-add
    multiplier forms the 48-bit product of the two 24-bit mantissas in 25 cycles —
    {!Multiplier} in miniature — and combinational logic around it handles the exponents,
    rounds and repacks.

    {1 Number format}

    IEEE-754 single precision, [{sign:1, exp:8 (bias 127), frac:23}], the leading 1
    implicit. An operand with exponent 0 counts as zero and gives a zero result. The
    result's sign is [x[31] ^ y[31]] and its exponent [xe + ye - 127], one more when the
    mantissa product reaches 2.0.

    {1 Timing}

    [run] is high while the core decodes FML; it is the enable and the synchronous clear,
    and there is no reset. With [run] high [S] walks from 0 to 25: 0 loads [x]'s mantissa,
    1..24 are the accumulate-and-shift steps, and at 25 [stall] drops with [z] valid. So
    [stall = run & ~(S == 25)]. *)

open Hardcaml

module I : sig
  type 'a t =
    { clock : 'a (** clock; the state counter [S] advances on each rising edge *)
    ; run : 'a (** [FML] decoded — enable + synchronous clear for the counter *)
    ; x : 'a (** 32-bit operand 1 (operand [B]) *)
    ; y : 'a (** operand 2, the register C0 (the FP units never take the immediate) *)
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

(** [?ce] (default [vdd]) is the clock enable the core passes on; see {!Divider.create}. *)
val create : ?ce:Signal.t -> Signal.t I.t -> Signal.t O.t

(** The mantissa product from one unsigned 24 x 24 multiply, which the synthesizer maps
    onto DSP48 blocks; the exponent and rounding logic is {!create}'s own. Combinational:
    [stall] never rises. Checked bit-identical to {!create} by a differential property
    test; it is not proven. [?ce] is accepted and ignored. *)
val create_opt : ?ce:Signal.t -> Signal.t I.t -> Signal.t O.t

(** {!create_opt} with the mantissa product passed through [stages] registers (1..15,
    default 2), which the synthesizer retimes into the DSP48; the multiply and the
    rounding then fall in different cycles. [stall] holds for [stages] cycles. Checked
    bit-identical to {!create} by a differential property test. [?ce] gates the pipeline. *)
val create_opt_pipelined : ?ce:Signal.t -> ?stages:int -> Signal.t I.t -> Signal.t O.t

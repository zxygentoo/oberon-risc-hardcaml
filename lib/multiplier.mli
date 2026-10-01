(** Signed and unsigned 32 x 32 -> 64 multiply, the MUL unit: a port of [Multiplier.v], a
    shift-and-add multiplier that takes 33 cycles and holds the core with [stall]
    meanwhile.

    {1 Timing}

    [run] is high while the core decodes MUL. It is the enable and also the synchronous
    clear: while it is low the state counter [S] stays at 0, so every multiply starts
    clean, and there is no reset. With [run] high [S] walks from 0 to 33: 0 loads [x],
    1..32 are the accumulate-and-shift steps, and at 33 [stall] drops with the product
    valid. So [stall = run & ~(S == 33)].

    {1 Signedness}

    [u] here means {e signed}: the core passes the inverse of the instruction's u bit. It
    affects only the first operand: on the last step the partial product is subtracted,
    which gives [x]'s top bit its negative weight. The second operand is sign-extended
    always. Unsigned MUL' therefore computes [x_unsigned * y_signed], and its high word
    differs from the emulators' whenever [y[31]] is set. *)

open Hardcaml

module I : sig
  type 'a t =
    { clock : 'a (** clock; the state counter [S] advances on each rising edge *)
    ; run : 'a (** [MUL]/[MUL'] decoded — enable + synchronous clear for the counter *)
    ; u : 'a (** signed mode: 1 = subtract the partial product on the last step *)
    ; x : 'a (** 32-bit multiplier (operand [B]) *)
    ; y : 'a (** 32-bit multiplicand (operand [C1]) *)
    }
  [@@deriving hardcaml]
end

module O : sig
  type 'a t =
    { stall : 'a (** high while [run] and [S<>33]; freezes the core's PC/IR *)
    ; z : 'a (** 64-bit product: [z[31:0]] → result [R.a], [z[63:32]] → [H] *)
    }
  [@@deriving hardcaml]
end

(** [?ce] (default [vdd]) is the clock enable the core passes on; see {!Divider.create}. *)
val create : ?ce:Signal.t -> Signal.t I.t -> Signal.t O.t

(** The same product from one signed 33 x 33 multiply, which the synthesizer maps onto
    DSP48 blocks. Combinational: [stall] never rises. It reproduces [Multiplier.v]'s sign
    handling ([y] always signed, [x] signed when [u]) and is checked bit-identical to
    {!create} by a differential property test; it is not proven. [?ce] is accepted and
    ignored, there being no state. *)
val create_opt : ?ce:Signal.t -> Signal.t I.t -> Signal.t O.t

(** {!create_opt} with the product passed through [stages] registers (1..15, default 2),
    which the synthesizer retimes into the DSP48 so that no single path spans the
    multiply. [stall] holds for [stages] cycles. Checked bit-identical to {!create} by a
    differential property test. [?ce] gates the pipeline. *)
val create_opt_pipelined : ?ce:Signal.t -> ?stages:int -> Signal.t I.t -> Signal.t O.t

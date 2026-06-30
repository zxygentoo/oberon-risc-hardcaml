(** [Multiplier] — iterative signed/unsigned 32×32→64 multiply; the RISC5 [MUL]/[MUL']
    unit.

    A faithful port of Oberon's [Multiplier.v]: a shift-and-add sequential multiplier that
    computes [z = x * y] over 33 cycles, holding the core with [stall] until its state
    counter reaches the terminal value.

    {1 Timing}
    (mirrored exactly from the RTL — AGENT.md §2/§8)

    [run] is asserted by the core while [MUL] is decoded, and doubles as enable {e and}
    synchronous clear: while [run] is low the 6-bit state counter [S] is pinned at 0, so
    the next multiply always begins from a clean load — there is no reset. Once [run]
    asserts, [S] walks 0→33: [S=0] loads [x], [S=1..32] are the 32 accumulate/shift
    iterations, and at [S=33] [stall] drops with the product valid. Thus
    [stall = run & ~(S==33)], and the core keeps PC/IR frozen for the whole run.

    {1 Signedness}

    The module's [u] is the {e signed} flag: the core drives it as [~u] (the inverse of
    the ISA u-bit), so ISA [MUL] (signed) → [u=1] and [MUL'] (unsigned) → [u=0]. [u] flips
    only the {e first} operand [x]: on the last step ([S=32]) it subtracts the partial
    product, giving [x]'s MSB its negative two's-complement weight. The {e second} operand
    [y] is sign-extended unconditionally — so unsigned [MUL'] computes
    [x_unsigned × y_signed], which is why its high word diverges from the emulators when
    [y[31]=1] (AGENT.md §8). *)

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

(** [create] is the [MUL] unit as a Hardcaml [I]-to-[O] interface, for instantiation and
    simulation. [?ce] is the board clock-enable (default [vdd]); see {!Divider.create}. *)
val create : ?ce:Signal.t -> Signal.t I.t -> Signal.t O.t

(** [create_opt] — the Phase-9 optimised drop-in for {!create} (AGENT.md §5): the same
    32×32→64 multiply expressed as a single signed 33×33 multiply, which Vivado lowers
    onto the board's DSP48 slices. {b Combinational} — it retires in one cycle ([stall]
    tied low) instead of {!create}'s 33. Bit-identical to {!create} for every input: it
    reproduces [Multiplier.v]'s §8 sign handling ([y] always signed, [x] signed iff [u]),
    proven by the co-located differential qcheck against the formally-proven {!create}
    rather than re-formalised. [?ce] is accepted for signature compatibility but ignored
    (no state). *)
val create_opt : ?ce:Signal.t -> Signal.t I.t -> Signal.t O.t

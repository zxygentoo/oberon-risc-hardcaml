(** [Divider] — iterative restoring division; the RISC5 [DIV]/[DIV'] unit.

    A faithful port of Oberon's [Divider.v]: a restoring sequential divider that computes
    the quotient and remainder of [x]/[y] over 33 cycles, sharing the Multiplier's exact
    state/stall skeleton — 6-bit counter [S], [stall = run & ~(S=33)], [run]-gated with no
    reset (see {!Multiplier}).

    {1 Precondition: [y > 0]}

    The divisor must lie in [1 .. 2^31-1] (i.e. [i32 y > 0], top bit clear) — Wirth's
    [// y > 0]. The restoring step uses the 32-bit trial difference's MSB as the
    "remainder < divisor" test, which only holds while the partial remainder stays below
    [2^31]; a divisor of 0 or with bit 31 set breaks it. The core and oracle uphold this
    (the oracle takes a separate path for [i32 y <= 0]).

    {1 Signedness — floored division}

    [u] is the {e signed} flag — the core drives it [~u], so ISA [DIV] → [u=1] (signed),
    [DIV'] → [u=0] (unsigned). Signed mode divides [|x|]/[y] then sign-corrects
    to **floored** division (toward −∞) with a {e non-negative} remainder: for [x<0],
    [quot = -(|x|/y)] when it divides evenly else [-(|x|/y) - 1], with [rem = 0] or
    [y - (|x| mod y)] to match. [quot] → result [R.a], [rem] → [H]. *)

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

(** [create] is the [DIV] unit as a Hardcaml [I]-to-[O] interface, for instantiation and
    simulation. *)
val create : Signal.t I.t -> Signal.t O.t

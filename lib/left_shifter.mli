(** [Left_shifter] — combinational logical left shift; the RISC5 [LSL] datapath unit.

    Mirrors Oberon's [LeftShifter.v]: [y = x << sc], zero-filled, with [sc] a 5-bit count
    (shift of 0..31). In the core it is fed operand [B] and [C1[4:0]] — the low 5 bits of
    the second operand (see [RISC5.v:57]). *)

open Hardcaml

module I : sig
  type 'a t =
    { x : 'a (** 32-bit operand *)
    ; sc : 'a (** 5-bit shift count (0..31) *)
    }
  [@@deriving hardcaml]
end

module O : sig
  type 'a t = { y : 'a (** [x << sc], zero-filled *) } [@@deriving hardcaml]
end

(** [create] is the [LSL] unit as a Hardcaml [I]-to-[O] interface, for instantiation and
    simulation. *)
val create : Signal.t I.t -> Signal.t O.t

(** [Left_shifter] — combinational logical left shift; the RISC5 [LSL] datapath unit.

    Mirrors Oberon's [LeftShifter.v]: [y = x << sc], zero-filled, with [sc] a 5-bit count
    (shift of 0..31). In the core it is fed operand [B] and [C1[4:0]] — the low 5 bits of
    the second operand (see [RISC5.v:57]). *)

open Hardcaml

(** [shift ~x ~sc] is [x] shifted logically left by the low bits of [sc]. Exposed so the
    ALU can use it inline as well as through {!create}. *)
val shift : x:Signal.t -> sc:Signal.t -> Signal.t

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

(** [create] wraps {!shift} as a Hardcaml [I]-to-[O] interface — the [LSL] unit for
    instantiation and simulation. *)
val create : Signal.t I.t -> Signal.t O.t

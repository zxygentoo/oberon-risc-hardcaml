(** [Right_shifter] — combinational right shift: ASR (arithmetic) and ROR (rotate); the
    RISC5 [ASR]/[ROR] datapath unit.

    Mirrors Oberon's [RightShifter.v]: a barrel right-shift by [sc] (a 5-bit count, 0..31)
    whose vacated top bits are filled by [md] — the sign bit for ASR ([md] = 0), the
    outgoing low bits for ROR ([md] = 1). In the core it is fed operand [B], [C1[4:0]],
    and [md = IR[16]] (= op[0], "is ROR"); see [RISC5.v:59]. RISC5 has no logical shift
    right — ASR and ROR are the only right shifts. *)

open Hardcaml

(** [shift ~x ~sc ~md] is [x] shifted right by the low bits of [sc]: arithmetic
    (sign-filled) when [md] is 0, rotate (wrap-filled) when [md] is 1. Exposed so the ALU
    can use it inline as well as through {!create}. *)
val shift : x:Signal.t -> sc:Signal.t -> md:Signal.t -> Signal.t

module I : sig
  type 'a t =
    { x : 'a (** 32-bit operand *)
    ; sc : 'a (** 5-bit shift count (0..31) *)
    ; md : 'a (** mode: 0 = ASR (sign fill), 1 = ROR (rotate) *)
    }
  [@@deriving hardcaml]
end

module O : sig
  type 'a t = { y : 'a (** [x] shifted right, [md]-filled *) } [@@deriving hardcaml]
end

(** [create] wraps {!shift} as a Hardcaml [I]-to-[O] interface — the [ASR]/[ROR] unit for
    instantiation and simulation. *)
val create : Signal.t I.t -> Signal.t O.t

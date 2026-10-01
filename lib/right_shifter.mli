(** Right shift, the ASR and ROR unit ([RightShifter.v]): a shift by [sc] (0..31) whose
    vacated top bits take the sign ([md] = 0, ASR) or the bits shifted out ([md] = 1,
    ROR). The core feeds it operand B, the low five bits of operand 2, and [md = IR[16]].
    RISC5 has no logical shift right. *)

open Hardcaml

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

val create : Signal.t I.t -> Signal.t O.t

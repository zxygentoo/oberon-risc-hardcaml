(** Logical left shift, the LSL unit ([LeftShifter.v]): [y = x << sc], zero-filled, for a
    5-bit count. The core feeds it operand B and the low five bits of operand 2. *)

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

val create : Signal.t I.t -> Signal.t O.t

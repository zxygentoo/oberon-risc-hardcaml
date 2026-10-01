(** The register file ([Registers.v]): sixteen 32-bit registers, three asynchronous read
    ports and one synchronous write port.

    The RTL builds it from [RAM16X1D] primitives, duplicated to provide the third read
    port. Only the behaviour is kept here, as a [multiport_memory], and synthesis infers
    the distributed RAM.

    [dout0]/[dout1]/[dout2] are combinational functions of [rno0]/[rno1]/[rno2]; [din] is
    written to register [rno0] at the clock edge when [wr] is high. [rno0] is both read
    address 0 and the write address. There is no reset; the registers power up as 0. *)

open Hardcaml

module I : sig
  type 'a t =
    { clock : 'a (** write clock *)
    ; wr : 'a
    (** write enable ([regwr]): when high, [din] is written to register [rno0] at the edge *)
    ; rno0 : 'a
    (** read port 0 address — also the write address ([ira0]; 15 on branch-link) *)
    ; rno1 : 'a (** read port 1 address ([irb]) *)
    ; rno2 : 'a (** read port 2 address ([irc]) *)
    ; din : 'a (** write data ([regmux]) *)
    }
  [@@deriving hardcaml]
end

module O : sig
  type 'a t =
    { dout0 : 'a (** R[rno0] (= [A]) *)
    ; dout1 : 'a (** R[rno1] (= [B]) *)
    ; dout2 : 'a (** R[rno2] (= [C0]) *)
    }
  [@@deriving hardcaml]
end

val create : Signal.t I.t -> Signal.t O.t

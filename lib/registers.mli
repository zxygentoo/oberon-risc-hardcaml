(** [Registers] — the RISC5 triple-port register file ([Registers.v]): three asynchronous
    read ports and one synchronous write port over sixteen 32-bit registers.

    Wirth builds it from dual-port [RAM16X1D] distributed-RAM primitives (each gives one
    read at the write address plus one read-only second port), duplicated to provide the
    third read port. That duplication is {e structure}, not spec (AGENT.md §2/§3): we keep
    only the behaviour — three async reads, one sync write — via [multiport_memory], and
    let synthesis infer the distributed RAM.

    Timing (AGENT.md §8): [dout0/1/2] are combinational functions of [rno0/1/2] (no
    clock); [din] is written to register [rno0] on the clock edge when [wr]. [rno0] is
    both read port 0 and the write address. No reset — registers power up to 0. *)

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

(** [create] instantiates the 16×32 array: one synchronous write port at [rno0], three
    asynchronous read ports at [rno0/rno1/rno2]. *)
val create : Signal.t I.t -> Signal.t O.t

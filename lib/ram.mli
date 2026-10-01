(** 1 MiB of single-port main memory: the simulation model of the OberonStation's external
    asynchronous SRAM. (RISC5Top has no such module; it wires the SRAM through tri-state
    buffers.)

    The read is asynchronous: [rdata] is the word at [adr], combinationally, as the core's
    load path and the video DMA both require. The write is synchronous: when [wr] is high
    the word at [adr] is written at the clock edge — all four bytes for a word access
    ([ben] = 0), or the byte selected by [adr[1:0]] for a byte access. Memory starts as
    zero, like the oracle's.

    There is one port. The video controller shares it by stealing the address during its
    DMA cycle, which is why the core stalls then; that mux belongs to the SoC. *)

open Hardcaml

module I : sig
  type 'a t =
    { clock : 'a (** write clock *)
    ; adr : 'a (** 20-bit byte address into the 1 MiB space (word = [adr[19:2]]) *)
    ; wr : 'a (** write enable: when high, store at [adr] on the clock edge *)
    ; ben : 'a (** byte enable: 0 = word (all four lanes), 1 = the [adr[1:0]] byte lane *)
    ; wdata : 'a
    (** store data (the core's [outbus]; for a byte store the core has already placed the
        byte in its lane) *)
    }
  [@@deriving hardcaml]
end

module O : sig
  type 'a t = { rdata : 'a (** the 32-bit word at [adr] — combinational (async read) *) }
  [@@deriving hardcaml]
end

val create : Signal.t I.t -> Signal.t O.t

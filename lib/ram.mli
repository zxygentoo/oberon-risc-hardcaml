(** 1 MiB single-port main memory — the simulation model of the OberonStation's external
    {b asynchronous SRAM}. (In RISC5Top this is not a module of its own: the SRAM is wired
    through tri-state IOBUFs, read onto [inbus0] and written from [outbus], with per-byte
    write-enables.)

    {b Asynchronous read} — [rdata] is the word at [adr], combinational, like the real
    SRAM the core's load path and the video DMA both depend on.
    {b Synchronous byte-enable write} — when [wr], the word at [adr] is written on the
    clock edge: all four byte lanes for a word access ([ben]=0), or just the lane selected
    by [adr[1:0]] for a byte access ([ben]=1), mirroring the SRAM's per-byte write-enables
    ([SRbe]). The store data is the core's [outbus] (byte-replicated by the core for byte
    stores). Memory starts zeroed, as the oracle's does.

    {b Single-port by design.} The video controller shares this one port via DMA
    (RISC5Top's [SRadr = vidreq ? vidadr : adr]), which is precisely why the core stalls
    during DMA. That address-steal mux and [stall_x] live one level up in the SoC (Phase
    6); here the model is a clean single port. *)

open Hardcaml

module I : sig
  type 'a t =
    { clock : 'a (** write clock *)
    ; adr : 'a (** 20-bit byte address into the 1 MiB space (word = [adr[19:2]]) *)
    ; wr : 'a (** write enable: when high, store at [adr] on the clock edge *)
    ; ben : 'a (** byte enable: 0 = word (all four lanes), 1 = the [adr[1:0]] byte lane *)
    ; wdata : 'a
    (** 32-bit store data (the core's [outbus] — byte-replicated by the core for byte
        stores) *)
    }
  [@@deriving hardcaml]
end

module O : sig
  type 'a t = { rdata : 'a (** the 32-bit word at [adr] — combinational (async read) *) }
  [@@deriving hardcaml]
end

(** [create i]: [rdata] = word at [i.adr]; on [i.wr], write [i.wdata] there (word, or the
    [i.adr[1:0]] byte lane when [i.ben]). [adr] is a byte address within 1 MiB. *)
val create : Signal.t I.t -> Signal.t O.t

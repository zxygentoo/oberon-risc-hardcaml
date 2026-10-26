(** A direct-mapped, write-through read cache in front of {!Cellram}. The running OS
    fetches every instruction from the PSRAM, a multi-cycle read; a hit here is served
    combinationally from distributed RAM on the FPGA.

    {1 Placement, and why a hit costs nothing}

    {!Soc} puts the cache between the core's memory port and {!Cellram}. On a hit it
    withholds [mem_pend] from Cellram, whose [ce] is [~mem_pend | …], so [ce] is high in
    the same cycle, and the word is taken from here. Misses and stores go through Cellram
    unchanged. The read is asynchronous, which is what makes the hit free, and what makes
    the arrays distributed RAM: block RAM cannot be read combinationally.

    {1 Coherence}

    The original machine has no cache, so Oberon has no instruction to flush one:
    coherence has to be automatic. It rests on one invariant, that
    {b a valid line always equals the PSRAM}. A fill copies the PSRAM, and the cache
    writes nothing to memory itself, so a line can only go stale through a store to its
    address — and every store is watched: a store to a cached line drops the line, or
    refreshes it (see [write_update]). The cases:
    - CPU after CPU, including the module loader writing code and then jumping into it:
      the store is seen, so the later fetch cannot read stale code;
    - video after CPU: stores still go to the PSRAM, which video reads through its own
      port;
    - CPU after video: video only reads.

    The invariant holds at all times, so no reset is needed: the distributed RAM comes up
    as zeros, every line invalid, and across a warm reset the lines kept still equal the
    PSRAM.

    {1 Geometry}

    One 32-bit word per line, over the whole 16 MiB: [adr[23:2]] is the word address, its
    low [lines_log2] bits the index and the rest the tag. The core never stores and reads
    in one cycle, so one write port serves both the fill and the store. *)

open Hardcaml

module I : sig
  type 'a t =
    { clock : 'a
    ; adr : 'a (** core byte address [adr[23:0]] (a fetch or a load/store) *)
    ; cacheable_read : 'a
    (** a fetch/load bound for PSRAM: [mem_pend & ~wr & ~cpu_internal] (ROM/MMIO excluded) *)
    ; write : 'a
    (** a store bound for PSRAM: [wr & ~cpu_internal] — snooped for coherence *)
    ; ben : 'a
    (** the core's byte-access flag: 1 = byte store — write-update can't merge one lane,
        so a byte store-hit always invalidates *)
    ; ce : 'a (** [Cellram.ce]: the access-retire pulse — a read miss fills on it *)
    ; fill_data : 'a (** [Cellram.rdata]: the fetched word, valid at [ce] on a miss *)
    ; wdata : 'a
    (** the core's store data ([outbus]) — the word a write-update writes into a hit line
        (exact for word stores; byte stores never update) *)
    }
  [@@deriving hardcaml]
end

module O : sig
  type 'a t =
    { hit : 'a (** combinational: [cacheable_read & valid & tag-match] *)
    ; rdata : 'a (** the cached word (meaningful when [hit]) *)
    }
  [@@deriving hardcaml]
end

(** [lines_log2] (default 10: 1024 lines, 4 KiB of data) must be in 1..21; the tag is
    [22 - lines_log2] bits.

    [write_update] (default [false]) changes what a {b word} store does to a line it hits:
    instead of dropping the line it rewrites it with the store data, in the same
    transaction that puts the word in the PSRAM, so the invariant is untouched. A byte
    store still drops the line, since merging one byte would need a read. It matters
    because Oberon stores to a stack slot and loads it straight back: with lines dropped,
    almost all load misses were on lines a store had just dropped, whatever the size of
    the cache. *)
val create : ?lines_log2:int -> ?write_update:bool -> Signal.t I.t -> Signal.t O.t

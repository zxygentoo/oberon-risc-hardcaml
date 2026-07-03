(** [Cache] — Phase-10a: a direct-mapped, write-through instruction/read cache in front of
    {!Cellram} (AGENT.md §5). The Phase-9 benchmark showed the machine is memory-bound —
    the running OS fetches every instruction from PSRAM — so this cuts fetch/load latency:
    a hit is served combinationally from on-chip distributed RAM instead of a multi-cycle
    PSRAM read (measured ~6x on running-OS code, 93% hit-rate;
    test/boards/nexys-4/bench_boot.ml).

    {1 Placement & the 0-stall hit}

    The cache lives in the board layer, never [lib/], so the core stays byte-identical and
    its Phase-8 equivalence to [RISC5.v] is untouched (§2/§3); the latency it fights is a
    board phenomenon (the [lib/] sim has single-cycle memory). {!Soc} wires it between the
    core's memory port and {!Cellram}: on a hit it drops [mem_pend] to Cellram, whose [ce]
    is [~mem_pend | …], so [ce] rises the same cycle — a {b 0-stall} hit — and the word is
    muxed from here in place of [Cellram.rdata]. Misses and stores flow through Cellram
    unchanged. The read is {b asynchronous} (combinational): that is what makes the hit
    0-stall and what forces the tag/data arrays to synthesise as {b distributed RAM}
    (LUTRAM — BRAM cannot read combinationally), the same [multiport_memory] async-read
    idiom as the register file (§8). On the Nexys 4 this closes 60 MHz with the fill path
    as the critical path.

    {1 Coherence — transparent by construction, no flush instruction}

    The real machine has no cache, so Oberon has no cache-flush op — coherence must be
    automatic. It rests on one invariant: {b a valid line's data always equals PSRAM},
    because
    (a) fills copy PSRAM and (b) the cache issues no memory writes of its own —
        [Cellram]'s write path is unchanged (write-through) — so the only way a line could
        go stale is a write to its address, which we {e snoop}: a CPU store to a cached
        line invalidates it. The three cases (§5):
        - {b CPU→CPU}, incl. the module loader writing code then jumping into it —
          snoop-invalidate, so the later fetch cannot read stale code (the case that would
          otherwise trap the OS);
        - {b CPU→video} (framebuffer) — write-through keeps PSRAM current, so the video
          DMA (its own Cellram read port, never cached) always sees live pixels;
        - {b video→CPU} — video only reads; nothing to snoop.

    Because the invariant holds {e continuously}, {b no reset-invalidate is needed}: the
    distributed RAM powers up [INIT=0] (all lines invalid) at configuration, and across a
    warm reset the retained lines still equal PSRAM (the CPU is the sole writer, every
    store is snooped, and external PSRAM persists). Verified on silicon (boots clean) and
    in sim by the board visual golden — byte-identical desktop with the cache on
    (test/boards/nexys-4/test_visual_golden_board.ml) — and the running-OS lockstep bench.

    {1 Geometry}

    Direct-mapped, one 32-bit word per line, over the 1 MB window: [adr[19:2]] is the
    18-bit word address, its low [lines_log2] bits the index, the rest the tag. A store
    and a read never occur in the same core cycle (single-issue), so one write port serves
    both fill (read-miss retire) and invalidate (snooped store). *)

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

(** [create ?lines_log2 ?write_update i] builds the cache. [lines_log2] (default 10 = 1024
    lines = 4 KiB of data) is log2 of the number of direct-mapped lines, valid 1..17
    (checked; 18 would need a degenerate 0-bit tag); the tag is [18 - lines_log2] bits.

    [write_update] (default [false] = the proven Phase-10a snoop-invalidate) switches the
    store-hit snoop from {e invalidate} to {e update-in-place} for {b word} stores: the
    line is rewritten with the store data through the same single write port, in the same
    write-through transaction that lands the word in PSRAM — so the coherence invariant (a
    valid line equals PSRAM) is untouched. Byte stores still invalidate (merging one lane
    needs read-modify). Why: the Phase-10b miss autopsy
    (test/boards/nexys-4/bench_boot.ml) measured {b 96.1% of running-OS load misses} to be
    snoop-invalidate self-inflicted — Oberon's store-then-load stack discipline kills the
    hot lines — capping load hit-rate at ~59% no matter the capacity; update-in-place
    lifts it to ~98%. *)
val create : ?lines_log2:int -> ?write_update:bool -> Signal.t I.t -> Signal.t O.t

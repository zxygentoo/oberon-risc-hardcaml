(** [Framebuf] — Phase-10c: the framebuffer shadowed in on-chip BRAM, so the video DMA
    never touches the PSRAM port (AGENT.md §5).

    The Phase-10 stall profile put the video bus tax at a measured {b 1.228×} same-work
    ceiling (bench_boot's [?video] A/B): the PSRAM port serves video ~23% of all clocks,
    and ~9% of clocks the CPU sits frozen while it does. This module removes that traffic
    at the source — and with it the need for {!Cellram}'s video arbitration {e and}
    read-preemption logic (with [vidreq] tied low the synthesizer prunes both).

    {1 Design: a write-through shadow, PSRAM keeps the truth}

    Same shape as {!Cache}'s coherence argument, applied to the framebuffer window:

    - {b CPU stores are mirrored.} Every PSRAM-bound store whose word address falls in the
      DMA-addressable span [[Video.org, Video.org + 0x8000)] also writes the shadow — in the
      same write-through transaction that lands the word in PSRAM, so shadow and PSRAM
      window stay equal at every instant (both power up zeroed: BRAM [INIT=0] at
      configuration, and the OS paints the whole screen before showing it).
    - {b CPU loads are untouched.} They read PSRAM/cache exactly as today (PSRAM has the
      truth), so nothing changes on the CPU read path — no new read port, no mux.
    - {b Video reads the shadow.} A {!Video} fetch ([vidreq]/[vidadr]) becomes a 1-cycle
      synchronous BRAM read: [vid_ack] the next clock, trivially inside the prefetch's
      ~2-group-time budget — vs the ~11-cycle arbitrated PSRAM read it replaces.

    The span is the {e full} 32768 words {!Video.lookahead} can address ([org + {~vcnt,
    col}], 128 KB ≈ 32 of the 135 unused BRAM tiles), not just the visible 24576 — so no
    assumption is needed about which rows the raster fetches during blanking.

    {1 Geometry}

    Four byte-lane BRAMs (32768 × 8 each, the {!Risc5.Ram} idiom) share the word index, so
    a byte store writes exactly its lane — no read-modify-write. Sync read is what lets
    the arrays infer as {b block} RAM (the cache's async-read LUTRAM idiom would burn
    ~26k LUTs here). *)

open Hardcaml

(** The shadow's window in 18-bit word addresses: [[base, base + size)]. [base] is
    {!Risc5.Video.org}; [size] is the full 32768-word DMA-addressable span. Exported for
    harnesses that read the shadow back (the board visual golden's shadow-vs-PSRAM
    equality check). *)
val base : int

val size : int

module I : sig
  type 'a t =
    { clock : 'a
    ; adr : 'a (** core byte address [adr[23:0]] (a store's target) *)
    ; write : 'a
    (** a PSRAM-bound store: [wr & ~cpu_internal] — mirrored into the shadow when its word
        address falls in the framebuffer span *)
    ; ben : 'a (** the core's byte-access flag: 1 = byte store (one lane written) *)
    ; wdata : 'a (** the core's store data ([outbus], already byte-replicated) *)
    ; vidreq : 'a (** video fetch request (1-cycle pulse; {!Video}'s [req]) *)
    ; vidadr : 'a (** framebuffer word address of the fetch ({!Video}'s [vidadr]) *)
    }
  [@@deriving hardcaml]
end

module O : sig
  type 'a t =
    { viddata : 'a (** the fetched framebuffer word, valid at [vid_ack] *)
    ; vid_ack : 'a
    (** pulse: the read issued at [vidreq] completed (the following clock) *)
    ; vidpar : 'a
    (** parity (column LSB) of the completing fetch, valid with [vid_ack] — picks
        {!Video}'s ping-pong prefetch buffer, same contract as [Cellram.vidpar] *)
    }
  [@@deriving hardcaml]
end

val create : Signal.t I.t -> Signal.t O.t

(** The framebuffer shadowed in block RAM on the FPGA, so that the video DMA never touches
    the PSRAM port. Without it that port serves video about 23% of the time, and the CPU
    waits meanwhile. With [vidreq] to {!Cellram} tied low, the synthesizer also removes
    Cellram's video arbitration and its read preemption.

    {1 A write-through shadow; the PSRAM keeps the truth}

    The same shape as {!Cache}'s coherence argument:
    - CPU stores are mirrored. Every store bound for the PSRAM whose word address falls in
      the span the DMA can address, [[Video.org, Video.org + 0x8000)], also writes the
      shadow, in the same transaction, so the shadow follows that window of the PSRAM
      store for store.
    - CPU loads are untouched: they read the PSRAM, or the cache, as before.
    - Video reads the shadow: a fetch is a one-cycle synchronous read, with [vid_ack] on
      the next clock.

    In simulation the two start equal, both zero. On the board the PSRAM powers up with
    arbitrary contents, which does not matter: only the shadow is displayed, and the OS
    paints the whole screen before showing it.

    The span is the whole 32768 words {!Video.lookahead} can address, not only the 24576
    visible ones, so nothing is assumed about which rows the raster fetches during
    blanking.

    {1 Geometry}

    Four byte-lane RAMs of 32768 bytes share the word index, so a byte store writes
    exactly its lane. The synchronous read is what lets them infer as block RAM. *)

open Hardcaml

(** The shadow's window in word addresses, [[base, base + size)]: [base] is
    {!Risc5.Video.org}, [size] the 32768 words. Exported for test harnesses that read the
    shadow back. *)
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

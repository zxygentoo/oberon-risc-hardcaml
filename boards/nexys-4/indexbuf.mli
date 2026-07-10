(** [Indexbuf] — the machine's indexed-colour (chunky 8bpp) display mode: a 320x200
    byte-per-pixel framebuffer scanned out to the 1024x768 mono panel through a
    CPU-programmed luminance LUT and a CPU-UPLOADED ordered-dither threshold map.

    The Phase-10c {!Framebuf} trick applied a second time: a write-through shadow of the
    himem windows below serves {!Risc5.Video}'s [vidreq] (mode-muxed against Framebuf)
    with a small FSM that composes each requested mono word on the fly — 10 source bytes →
    LUT → threshold compares. The hardware is CONTENT-FREE: geometry (320x200 →
    fullscreen, the mode-13h fit this panel forces) is the mode itself and is baked;
    everything with taste in it — the palette luminances AND the 64x64 threshold map —
    arrives from the client at runtime. DOOM uploads its blue noise (libc/dither.c's
    [__dg_upload_thresholds]); any other client brings its own rendition (Mandel.Mod
    uploads a computed Bayer matrix). One client's data appears nowhere in the design;
    {!Bluenoise} survives only as test-oracle data pinning the DOOM equivalence.

    {1 The windows}

    Pixel window, 64 KiB at {!base} (= [0x310000], the DOOM ABI §8 back-buffer row):
    - [+0 .. +63999] — pixel bytes, row-major 320x200, row 0 = top of the image
    - [{!lut_off} .. +64255] — the luminance LUT (index = palette byte)
    - [{!ctl_off}] — control word: bit 0 = mode (1 = scan out from this buffer)

    Threshold window, 8 KiB at {!thr_base} (= [0x30E000], carved from the §8 spare row):
    2048 slot quads, word [a] = [{row[6], phase[1], slot[4]}] packing the slot's 3-or-4
    thresholds one byte each (LSB = leftmost output bit; K=3 slots padded with 255 — a
    compare an 8-bit luminance can never win; threshold column of output bit [b] =
    [32*phase + b]). A client derives the quads from its 64x64 threshold map — the OCaml
    shape is [slot_quad] in the ml (tests), the C shape [__dg_upload_thresholds] (DOOM
    blob), the Oberon shape [Mandel.Upload]. {b Mode-on requires a prior upload}: the RAM
    powers up zero, and all-zero thresholds render every non-black pixel white.

    {1 Coherence and timing}

    Stores tap the same write-through transaction {!Framebuf} snoops (PSRAM keeps the
    truth; CPU loads never touch this module). A compose takes 12 clk from [vidreq] to
    [vid_ack] — inside Video's ~2-group prefetch budget (~59 clk at 60 MHz) and its
    ~29.5-clk sustained request spacing. All memories are sync-read byte-lane BRAMs (the
    pixel-shadow idiom) except the 256-byte LUT (async LUTRAM, keeping the compute stage
    one cycle); the row-map geometry ROM reads at request-accept, the threshold RAM at the
    issue stage — both land their registered outputs exactly when consumed, so neither
    costs latency. *)

open Hardcaml

(** Byte base of the 64 KiB pixel window: [0x310000] (draft seam indexbuf-seam.md). *)
val base : int

(** Pixel window size in bytes (64 KiB — decode is [adr[23:16] = base >> 16]). *)
val size : int

(** LUT: byte offset 64000 ([0xFA00]) .. +255 within the pixel window. *)
val lut_off : int

(** Control word: byte offset 64256 ([0xFB00]); bit 0 = mode. *)
val ctl_off : int

(** Byte base of the 8 KiB threshold window: [0x30E000] (decode [adr[23:13]]). *)
val thr_base : int

(** Threshold window size in bytes (8 KiB = 2048 quads). *)
val thr_size : int

module I : sig
  type 'a t =
    { clock : 'a
    ; adr : 'a (** core byte address (a store's target) *)
    ; write : 'a (** a PSRAM-bound store: [wr & ~cpu_internal], Framebuf's tap *)
    ; ben : 'a (** byte-access flag: 1 = byte store (one lane written) *)
    ; wdata : 'a (** store data ([outbus], already byte-replicated) *)
    ; vidreq : 'a (** video fetch request (1-cycle pulse; {!Risc5.Video}'s [req]) *)
    ; vidadr : 'a (** framebuffer word address of the fetch *)
    }
  [@@deriving hardcaml]
end

module O : sig
  type 'a t =
    { viddata : 'a (** the composed mono word, valid at [vid_ack] *)
    ; vid_ack : 'a (** pulse: the compose issued at [vidreq] completed (12 clk later) *)
    ; vidpar : 'a
    (** parity (column LSB) of the completing fetch — {!Framebuf}'s contract *)
    ; mode : 'a (** the control bit: 1 = the board should scan out from here *)
    }
  [@@deriving hardcaml]
end

val create : Signal.t I.t -> Signal.t O.t

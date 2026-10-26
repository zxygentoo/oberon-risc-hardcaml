(** An 8-bit display mode: a window of 8-bit pixels that the client fills is shown in a
    rectangle of the 1024x768 mono screen, dithered at scan-out through a tone table, a
    threshold map, a row map and scale registers that the client uploads. The hardware
    holds only the mechanism; tone, thresholds and geometry are all the client's.

    Like {!Framebuf} it is a write-through shadow, here of two windows of high memory, and
    it answers {!Risc5.Video}'s fetches from that shadow. The board selects between the
    two per request on {!O.claim}: inside the rectangle this module answers; outside it,
    and whenever the mode is off, the mono shadow does.

    {1 The pixel window (64 KiB at {!base} = [0x310000])}

    - [+0 .. +63999]: pixel bytes. Their layout is the client's: the row map gives each
      displayed row's byte offset in the window, so stride and double buffering are
      software.
    - [{!lut_off} .. +64255]: the tone table (index = pixel byte, value = 8-bit grey).
    - [{!ctl_off} ..]: the registers, written by word stores:

    {v
    reg     off  bits  semantics
    CTL     +0   [0]   mode (immediate; 1 = the rect scans out from this window)
    WIN_X   +4   11    rect left, panel px, multiple of 32 (claim selects whole fb words)
    WIN_Y   +8   10    rect top, panel px
    WIN_W   +12  11    rect width, px, multiple of 32; X+W <= 1024
    WIN_H   +16  10    rect height, px; Y+H <= 768
    XNUM    +20  12    horizontal scale numerator   (XNUM >= XDEN >= 1: upscale or 1:1)
    XDEN    +24  12    horizontal scale denominator
    XOFF    +28  16    starting source byte column (DDA seeds sx := XOFF at row start)
    v}

    The geometry registers are shadowed: a store lands in a shadow, and the shadows become
    active once per frame, on entry to vertical blanking, so the picture never tears in
    mid-frame. At power-up the active rectangle is empty and claims nothing. CTL bit 0
    takes effect at once. The registers cannot be read back: a load from the window reads
    the PSRAM.

    {1 The table window (8 KiB at {!thr_base} = [0x30E000])}

    - [+0 .. +4095]: the threshold map, 64x64 bytes in row order ([map[row*64 + col]]),
      written by byte or word stores.
    - [{!rowmap_off} .. +7167]: the row map, 768 words. Entry [y], a row of the rectangle,
      is [{thr_row[21:16], row_base[15:0]}]: the byte offset of its source row in the
      pixel window, and its row of the threshold map. Word stores only. All vertical
      geometry — scaling, letterboxing, flipping between buffers — is a software loop
      filling these words; the hardware has no vertical scaler.

    {1 The decision and the horizontal scaler}

    For each output pixel of a claimed word:
    [bit = lut[pix[row_base + sx]] > thr[thr_row][ox & 63]] (bit 0 of a word is the
    leftmost pixel), with [sx] stepped by the output pixel:

    {v
    row start (first claimed word of a rect row):  sx := XOFF;  acc := XDEN
    per output pixel:  emit(sx);  acc := acc + XDEN;
                       if acc > XNUM then (acc := acc - XNUM; sx := sx + 1)
    v}

    At 16/5 this deals source widths 3, 3, 3, 3, 4. The scaler's state carries across the
    words of a row, which relies on {!Risc5.Video} requesting every visible word in raster
    order, as it does. Fetches during blanking are never claimed.

    {1 Frame sync}

    Video issues no fetch during vertical blanking, so here blanking shows as a gap in the
    requests: about 47,000 clocks of silence, against about 300 for the longest gap within
    a frame. A saturating counter detects it, with no clock-domain crossing and no change
    to Video. {!O.status} bit 0 is the blanking flag, raised early in the blanking
    interval, and bits 15..8 count frames, stepping on that same edge — the one that also
    makes the geometry shadows active. The SoC puts [status] at MMIO slot 10 ([0xFFFFE8],
    read only): the frame clock for a client that paces itself, or writes between frames.

    {1 Coherence and timing}

    Stores are taken from the same transaction {!Framebuf} takes them from; the PSRAM
    keeps the truth and CPU loads never involve this module. A claimed word takes 21
    clocks from request to acknowledge at any scale: two output pixels per clock, over a
    sliding window of two source words. A request arriving while a word is being composed
    is dropped, so those 21 clocks must fit between Video's requests, 32 pixels apart: the
    system clock must be faster than 42.7 MHz. The pixel and threshold memories are
    synchronous byte-lane block RAMs; the tone table is asynchronous distributed RAM, in
    two copies for the two lookups of a clock; the row map is one 32-bit RAM read when a
    request is accepted. *)

open Hardcaml

(** Byte base of the 64 KiB pixel window: [0x310000]. *)
val base : int

(** Pixel window size in bytes (64 KiB — decode is [adr[23:16] = base >> 16]). *)
val size : int

(** Tone LUT: byte offset 64000 ([0xFA00]) .. +255 within the pixel window. *)
val lut_off : int

(** Register block: byte offset 64256 ([0xFB00]); CTL at +0, geometry at +4..+28. *)
val ctl_off : int

(** Byte base of the 8 KiB table window: [0x30E000] (decode [adr[23:13]]). *)
val thr_base : int

(** Table window size in bytes (8 KiB: 4 KiB threshold map + the row map). *)
val thr_size : int

(** Row-map byte offset within the table window ([0x1000]): 768 words,
    [{thr_row[21:16], row_base[15:0]}], word stores only. *)
val rowmap_off : int

(** The status word's MMIO read slot, 10 (byte [0xFFFFE8]). The SoC passes it to
    {!Risc5.Peripherals.create}, which checks it against the other slots. *)
val status_slot : int

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
    ; vid_ack : 'a (** pulse: the claimed compose issued at [vidreq] completed *)
    ; vidpar : 'a
    (** parity (column LSB) of the completing fetch — {!Framebuf}'s contract *)
    ; claim : 'a
    (** latched at request-accept: 1 = this request is the rect's (mode on, visible row,
        word inside the rect) — the board's per-request Halftone/Framebuf mux *)
    ; status : 'a
    (** [{16'0, frame_ctr[8], 7'0, vblank}] — the SoC's MMIO slot 10 ([0xFFFFE8]) *)
    }
  [@@deriving hardcaml]
end

val create : Signal.t I.t -> Signal.t O.t

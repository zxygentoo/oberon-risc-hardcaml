(** [Halftone] — the machine's indexed/grayscale display mode, v2 (the generality rework):
    a client-defined 8bpp source window scanned out to a RECTANGLE of the 1024x768 mono
    panel through a CPU-uploaded tone LUT, threshold map, row map and scale registers —
    ordered dithering at scanout. The v1 experiment (DOOM's dither moved into hardware)
    baked the 320x200 → fullscreen geometry into ROMs; v2 keeps only MECHANISM in hardware
    — every policy (tone, thresholds, and now geometry) arrives from the client at
    runtime, so DOOM is one client among any Oberon program that wants grayscale pixels
    (the seam spec: the DOOM repo's ABI.md §11).

    The Phase-10c {!Framebuf} trick still: a write-through shadow of the himem windows
    below serves {!Risc5.Video}'s [vidreq] with a compose FSM; the board muxes
    Halftone/Framebuf per completing request on {!O.claim} — inside the rect this module
    answers, outside (and whenever the mode is off) the mono shadow does.

    {1 The pixel window (64 KiB at {!base} = [0x310000])}

    - [+0 .. +63999] — pixel bytes. MEANING IS CLIENT-DEFINED: the row map names each
      displayed row's byte offset in the window, so image layout/stride/double-buffering
      are all software policy.
    - [{!lut_off} .. +64255] — tone LUT (index = pixel byte, value = 8-bit gray).
    - [{!ctl_off} ..] — the register block, word stores:

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

    Geometry registers are SHADOWED: stores land in shadows, the hardware latches shadow →
    active once per frame at vblank entry (no mid-frame tearing; a zero-sized power-up
    rect claims nothing, so mode-off elaboration stays display-identical to a board
    without the module). CTL bit 0 is immediate — [exit()]'s instant desktop restore.
    Registers are write-only (CPU loads of the window read PSRAM truth); status is on MMIO
    (below).

    {1 The table window (8 KiB at {!thr_base} = [0x30E000])}

    - [+0 .. +4095] — threshold map, VERBATIM: 64x64 bytes row-major ([map[row*64 + col]];
      byte or word stores). The v1 slot-quad packing is gone.
    - [{!rowmap_off} .. +7167] — row map: 768 words, entry [y] (rect-relative output row)
      = [{thr_row[21:16], row_base[15:0]}] — the source row's byte offset in the pixel
      window and the threshold-map row for that output line. WORD STORES ONLY (one 32-bit
      RAM, no byte lanes). Any vertical scale/dealing/double-buffer flip is a software
      loop filling these words; no vertical DDA exists in hardware. DOOM uploads the exact
      out2 dealing, keeping hardware ≡ [__dg_dither_fs] bit-identical.

    {1 The decision function and the horizontal DDA (frozen)}

    Per output pixel of a claimed word:
    [bit = lut[pix[row_base + sx]] > thr[thr_row][ox & 63]] (bit 0 of a word = leftmost
    pixel), with [sx] advanced by the output-driven DDA:

    {v
    row start (first claimed word of a rect row):  sx := XOFF;  acc := XDEN
    per output pixel:  emit(sx);  acc := acc + XDEN;
                       if acc > XNUM then (acc := acc - XNUM; sx := sx + 1)
    v}

    At XNUM/XDEN = 16/5 this deals source widths 3,3,3,3,4 — exactly the v1 slot tables
    (pinned by the tests' full-frame hash). DDA state (and the FSM's 2-word source window)
    carries ACROSS the words of a rect row: correctness relies on {!Risc5.Video}'s
    raster-order request stream (every visible word, in order — true by construction of
    the prefetch). Blanking-time fetches ([y >= 768]) are never claimed.

    {1 Frame sync}

    Video issues NO fetches during vertical blanking ([req0] is gated with [~vblank]), so
    blanking is visible at this seam as a REQUEST GAP — ~47k clk of silence against ~300
    clk for the longest in-frame gap (hblank) — and a saturating watchdog detects it with
    no CDC and no Video changes: {!O.status} bit 0 = vblank (entry fires ~68 us into the
    ~786 us blanking), bits [15:8] = an 8-bit frame counter (increments at vblank entry —
    the edge that also latches the geometry shadows). The board SoC wires [status] into
    the MMIO read mux at slot 10 ([0xFFFFE8], read-only) — the machine's frame clock for
    [Halftone.Sync] and animation pacing.

    {1 Coherence and timing}

    Stores tap the same write-through transaction {!Framebuf} snoops (PSRAM keeps the
    truth; CPU loads never touch this module). A claimed compose takes 21 clk from
    [vidreq] to [vid_ack] at ANY scale — 2 output px/clock (one aligned 4-lane threshold
    read per beat PAIR, fixed pair accumulation) over a 2-word sliding source window (one
    pixel-shadow read per clock, its address pure registered state — at <= 2 source bytes
    per beat two window slides are never consecutive, the 60 MHz closure lesson) — inside
    Video's ~2-group prefetch budget (~59 clk at 60 MHz) and its ~29.5-clk sustained
    request spacing. All memories are sync-read byte-lane BRAMs except the tone LUT (async
    LUTRAM, replicated x2 for the two per-clock lookups); the row map is one 32-bit
    synchronous RAM read at request-accept. *)

open Hardcaml

(** Byte base of the 64 KiB pixel window: [0x310000] (ABI.md §11, the DOOM repo). *)
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

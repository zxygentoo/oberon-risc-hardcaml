(** Video controller — a faithful port of [VID60.v] (1024x768 @ 60 Hz, 1 bpp mono).

    Two jobs on two clocks: a VGA timing generator (hsync/vsync/blank + a pixel shift-out)
    on the 65 MHz pixel clock [pclk], and a framebuffer DMA that reads one 32-bit word (=
    32 pixels) from main memory every 32 pixels on the 25 MHz system clock [clk]. The DMA
    request [req] is the core's video stall ([stallX]); [vidadr] is the framebuffer word
    address; [viddata] is the word read back, shifted out one pixel per [pclk].

    [VID60.v] generates [pclk] internally with a Xilinx [DCM] (x13/5 of [clk]); that
    primitive is the Phase-7 board shim (the Nexys MMCM), so here [pclk] is an input.
    There is no reset — the raster counters free-run from their power-on (zero) state. *)

open Hardcaml

module I : sig
  type 'a t =
    { clk : 'a
    (** 25 MHz system/memory clock: the DMA handshake + prefetch buffers live here *)
    ; pclk : 'a (** 65 MHz pixel clock (DCM/MMCM-generated; a board-shim input here) *)
    ; inv : 'a (** invert video: white-on-black vs black-on-white *)
    ; viddata : 'a
    (** main-memory read data, latched into a prefetch buffer when the fetch word is valid
        (see [create]'s [?viddata_valid]) *)
    }
  [@@deriving hardcaml]
end

module O : sig
  type 'a t =
    { req : 'a (** SRAM read request = [stallX] into the core (one [clk] cycle / 32 px) *)
    ; vidadr : 'a (** framebuffer word address for the DMA read *)
    ; hsync : 'a (** horizontal sync, active low *)
    ; vsync : 'a (** vertical sync, active low *)
    ; rgb : 'a (** the 1 bpp pixel replicated across the 6 RGB pins *)
    }
  [@@deriving hardcaml]
end

(** Framebuffer base [Org] (a word address; byte 0xDFF00, = [DFF00H >> 2]). The DMA's
    [vidadr] is [org + {~vcnt(10), col(5)}], so every fetch lands in the 32768-word span
    [[org, org + 0x8000)] (rows 0..255 of it sit off-screen above the visible 768).
    Exported so a board layer shadowing the framebuffer (Phase 10c) covers exactly the
    span this module can address, with no second copy of the constant. *)
val org : int

(** The [vidadr] packing's field widths: [cols_log2] column bits (words per row) under
    [span_log2 - cols_log2] row bits — the whole DMA span is [2^span_log2] words above
    {!org}. Exported for the same reason as [org]: the board shadows size and decode their
    windows against this packing (which the [vid_addr] formal check pins) instead of
    keeping second copies. *)
val cols_log2 : int

val span_log2 : int

(** [pulse_sync ~src_spec ~dst_spec ~pulse] crosses a 1-cycle [pulse] in the [src_spec]
    clock domain into the [dst_spec] domain as a 1-cycle pulse, metastability-safe: a
    toggle flop in the source domain turns the pulse into a level, a 3-FF [dst_spec]
    synchroniser settles it, and an edge-detect regenerates one [dst_spec] pulse. The CDC
    primitive [vid] uses for the framebuffer fetch (the substitute for [VID60.v]'s
    async-set [req1]); proven no-loss/no-spurious for all clk/pclk phases in test/formal. *)
val pulse_sync
  :  src_spec:Signal.Reg_spec.t
  -> dst_spec:Signal.Reg_spec.t
  -> pulse:Signal.t
  -> Signal.t

(** Look-ahead framebuffer-address fields returned by {!lookahead}. *)
module Lookahead : sig
  type 'a t =
    { next_col : 'a (** the next 32-px column to be consumed (col+1, wrapping at 31→0) *)
    ; next_vcnt : 'a
    (** its row (vcnt, advanced when the column wraps; the visible top 767→0) *)
    ; vidadr : 'a (** packed framebuffer word address [Org + {~next_vcnt, next_col}] *)
    ; wpar : 'a
    (** ping-pong write parity (the bank the fetch lands in) = [lsb next_col] *)
    }
end

(** [lookahead ~hcnt ~vcnt] is the prefetch's combinational look-ahead addressing: from
    the raster counters it computes the NEXT consumed group's column/row, its packed word
    address, and the ping-pong bank its fetch lands in. The one address departure from
    [VID60.v] (whose address is the CURRENT group). Shared by {!create} and the [vid_addr]
    formal check, which proves it ≡ an independent geometry spec over all (hcnt, vcnt) —
    the addressing half of the prefetch-delivery decomposition (test/formal/README). *)
val lookahead : hcnt:Signal.t -> vcnt:Signal.t -> Signal.t Lookahead.t

(** [create i] builds the controller, cycle-faithful to [VID60.v] on the pixel/sync
    datapath, with two deliberate departures from the RTL:

    - {b Framebuffer-fetch CDC.} The RTL's async-set capture flop [req1] (RTL
      [always @(posedge req0, posedge clk)]) is unrepresentable in Cyclesim, so [req0]
      crosses [pclk]→[clk] through a TOGGLE PULSE SYNCHRONISER ([req_toggle] →
      [sync0]/[sync1]/[sync2] → edge-detect [req]) — the textbook metastability-safe
      crossing. It emits exactly one [clk] [req] per [req0] and is robust on real silicon
      (the [sync0]/[sync1] flops want an ASYNC_REG / CDC constraint in the board [.xdc]).

    - {b Two-group prefetch.} [VID60.v] requests the word for a 32-px group at the group's
      start and consumes it 31 px later (~480 ns) into a single [vidbuf] — too tight
      against PSRAM contention on the board (horizontal flicker). Here the request is
      issued ONE GROUP EARLY ([vidadr] targets the next consumed group, wrapping at column
      31 / row 767) into a PING-PONG double-buffer ([buf0]/[buf1], selected by column
      parity), so each fetch has ~2 group-times (~970 ns) to land. The displayed pixel
      stream is identical; only the fetch timing/structure differs. The Verilator co-sim
      against [VID60.v] no longer matches on [vidadr]/the fetch path by design.

    [?viddata_valid] is the board memory seam (default = [req]): single-cycle memory (the
    sim [Soc] cycle-steal) has [viddata] valid the cycle [req] fires, but the board's
    [Cellram] returns it some cycles later on its [vid_ack].

    [?viddata_par] selects which ping-pong buffer captures [viddata] (default =
    [lsb next_col], the live request parity, exact for the single-cycle path). The board's
    [Cellram] passes the parity of the fetch it is COMPLETING ([Cellram.vidpar]) so a
    slow, contended completion lands in the correct buffer regardless of the current
    raster phase. *)
val create
  :  ?viddata_valid:Signal.t
  -> ?viddata_par:Signal.t
  -> Signal.t I.t
  -> Signal.t O.t

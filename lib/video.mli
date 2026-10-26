(** Video controller, a port of [VID60.v]: 1024 x 768 at 60 Hz, one bit per pixel.

    Two jobs on two clocks. On the 65 MHz pixel clock [pclk], a raster generator: sync,
    blanking, and a shift register that sends one pixel per tick. On the system clock
    [clk], a framebuffer DMA that reads one 32-bit word, 32 pixels, from main memory for
    every 32 pixels shown. [req] is the DMA request (the core's [stallX] in the original
    SoC), [vidadr] the word address and [viddata] the word read.

    [VID60.v] generates [pclk] itself with a Xilinx DCM. Clock generation belongs to the
    board, so here [pclk] is an input. There is no reset: the raster counters run from
    their power-on state. *)

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

(** The framebuffer base as a word address (byte 0xDFF00). [vidadr] is
    [org + {~vcnt, col}], so every fetch falls in the 32768 words from [org]; the first
    256 rows of that span are off screen. Exported so that a board that shadows the
    framebuffer covers exactly this span. *)
val org : int

(** The field widths of that packing: [cols_log2] column bits under
    [span_log2 - cols_log2] row bits, [2^span_log2] words in all. *)
val cols_log2 : int

val span_log2 : int

(** [pulse_sync ~src_spec ~dst_spec ~pulse] carries a one-cycle pulse from one clock
    domain into another: a flop toggled by the pulse turns it into a level, three flops in
    the destination domain synchronise the level, and an edge detector makes one pulse of
    it again. It replaces [VID60.v]'s asynchronously set flop [req1]. A property proof
    (test/formal) shows that no pulse is lost or invented, whatever the phase of the two
    clocks. *)
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

(** [lookahead ~hcnt ~vcnt] gives, from the raster counters, the column and row of the
    group shown {e next}, its word address, and the buffer its fetch lands in. [VID60.v]
    addresses the current group; this is the one departure in addressing. The formal check
    [vid_addr] proves it equal to an independent statement of the geometry for every
    raster position. *)
val lookahead : hcnt:Signal.t -> vcnt:Signal.t -> Signal.t Lookahead.t

(** [create i] is the controller: [VID60.v]'s pixel and sync path cycle for cycle, with
    two deliberate departures.
    - {b The clock-domain crossing.} The RTL catches each fetch request in a flop set
      asynchronously from the pixel domain ([always @(posedge req0, posedge clk)]), which
      a cycle simulator cannot represent. Here the request crosses through {!pulse_sync}:
      one [clk] pulse per request, and safe on silicon, where the first two synchroniser
      flops want an ASYNC_REG or equivalent constraint.
    - {b Fetching one group ahead.} [VID60.v] requests a group's word when the group
      begins and consumes it 31 pixels later, about 480 ns. With slow, contended memory
      that deadline is missed and the picture tears horizontally. Here the request is made
      one group early, into two buffers used alternately ([buf0]/[buf1], by column
      parity), which gives each fetch about two group times. The pixels shown are the
      same; only when and where the word is fetched differs.

    [?viddata_valid] says when [viddata] holds the requested word. It defaults to [req]:
    memory that answers in the same cycle. A slower memory passes its own acknowledge.

    [?viddata_par] says which buffer the word goes to. It defaults to the parity of the
    request being made, which is right when the answer comes in the same cycle. A slower
    memory passes the parity of the fetch it is completing, so that a late word still
    lands in its own buffer. *)
val create
  :  ?viddata_valid:Signal.t
  -> ?viddata_par:Signal.t
  -> Signal.t I.t
  -> Signal.t O.t

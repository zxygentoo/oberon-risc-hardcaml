(** The board SoC's build knobs as one value. {!Soc.create} takes nothing else, so the
    Verilog emitter, the co-located tests and the simulation gates all name the machine
    they elaborate the same way: {!shipped} is the single statement of what the bitstream
    contains, {!bare} the starting point for everything smaller. *)

type t =
  { clocks_per_ms : int (** system clocks per millisecond (the ms-timer prescaler) *)
  ; read_cycles : int (** clocks per 16-bit PSRAM read phase *)
  ; write_cycles : int (** clocks per 16-bit PSRAM write phase *)
  ; spi_slow_div_log2 : int (** slow (SD-init) SPI clock = clk / 2^n *)
  ; multipliers : Risc5.Cpu.multipliers
  (** the units behind MUL and FML — see {!Risc5.Cpu.multipliers} *)
  ; icache : bool (** the direct-mapped read/I-cache in front of {!Cellram} ({!Cache}) *)
  ; lines_log2 : int (** cache size: 2^n one-word lines; consulted only when [icache] *)
  ; write_update : bool
  (** word store-hits refresh the cached line in place instead of dropping it; consulted
      only when [icache] *)
  ; fb_bram : bool
  (** video served from the {!Framebuf} shadow — a 1-cycle on-chip read — with
      {!Cellram}'s video port tied off *)
  ; halftone : bool
  (** instantiate the {!Halftone} display mode, claim-muxed against {!Framebuf} per video
      request, with its status word at MMIO slot 10. Needs [fb_bram]; {!Soc.create}
      refuses the combination otherwise. *)
  ; write_buffer : bool
  (** stores retire into a FIFO and drain in the background ({!Cellram.create}). Pair it
      with [fb_bram]: without the shadow a not-yet-drained framebuffer word could reach
      the raster a frame stale. *)
  ; wbuf_depth : int
  (** write-buffer FIFO depth, 1..4; consulted only when [write_buffer] *)
  ; uart_baud_slow : int (** UART clock divisor selected by [fsel = 0] *)
  ; uart_baud_fast : int (** UART clock divisor selected by [fsel = 1] *)
  }

(** The configuration the Nexys 4 bitstream is built from — emitted by [emit_verilog] and
    booted by the board gates in [test/board/nexys-4]. Retune the machine here. *)
val shipped : t

(** The board SoC with every extension off: the bare PSRAM controller at 2-cycle phases,
    no cache, shadow or write buffer, the iterative multipliers, and the original 25 MHz
    machine's timer, SPI and UART constants. The co-located tests and the boot
    checkpoint's first pass build from it ([{ bare with ... }]). *)
val bare : t

(** [cycles_of_ns c ~ns] is [ns] rounded up to whole system clocks of [c] — how a
    datasheet figure becomes a cycle count for {!Cellram_model}. *)
val cycles_of_ns : t -> ns:int -> int

(** one line naming every knob, for a gate's log *)
val to_string : t -> string

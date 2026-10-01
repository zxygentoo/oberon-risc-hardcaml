(** The board SoC's build knobs as one value — what {!Soc.create}'s optional arguments
    carry, bundled so the Verilog emitter and the simulation gates elaborate the {e same}
    machine: {!shipped} is the single statement of what the bitstream contains. *)

type t =
  { clocks_per_ms : int (** system clocks per millisecond (the ms-timer prescaler) *)
  ; read_cycles : int (** clocks per 16-bit PSRAM read phase *)
  ; write_cycles : int (** clocks per 16-bit PSRAM write phase *)
  ; spi_slow_div_log2 : int (** slow (SD-init) SPI clock = clk / 2^n *)
  ; fast_mul : bool (** DSP-backed MUL/FML in place of the iterative units *)
  ; mul_stages : int (** pipeline registers on the DSP multiplies; [0] = combinational *)
  ; icache : bool (** the direct-mapped read/I-cache in front of {!Cellram} *)
  ; lines_log2 : int (** cache size: 2^n one-word lines *)
  ; write_update : bool
  (** word store-hits refresh the cached line instead of dropping it *)
  ; fb_bram : bool (** video served from the {!Framebuf} shadow, off the PSRAM port *)
  ; halftone : bool (** instantiate the {!Halftone} display mode (needs [fb_bram]) *)
  ; write_buffer : bool (** stores retire into a FIFO and drain in the background *)
  ; wbuf_depth : int (** write-buffer FIFO depth, 1..4 *)
  ; uart_baud_slow : int (** UART clock divisor selected by [fsel = 0] *)
  ; uart_baud_fast : int (** UART clock divisor selected by [fsel = 1] *)
  }

(** The configuration the Nexys 4 bitstream is built from — emitted by [emit_verilog] and
    booted by the board gates in [test/board/nexys-4]. Retune the machine here. *)
val shipped : t

(** [cycles_of_ns c ~ns] is [ns] rounded up to whole system clocks of [c] — how a
    datasheet figure becomes a cycle count for {!Cellram_model}. *)
val cycles_of_ns : t -> ns:int -> int

(** one line naming every knob, for a gate's log *)
val to_string : t -> string

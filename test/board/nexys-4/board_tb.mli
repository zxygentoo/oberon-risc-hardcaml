(** Shared board-SoC test harness: {!Nexys4_board.Soc} closed with the behavioural PSRAM
    double {!Nexys4_board.Cellram_model} on its memory pins — the common wiring of the
    board boot checkpoint, the board visual golden, and bench_boot (all this dir). *)

open Hardcaml
module I = Nexys4_board.Soc.For_tests.Tb.I
module O = Nexys4_board.Soc.For_tests.Tb.O

(** [drive_idle inp] = {!Nexys4_board.Soc.For_tests.drive_idle}: every input to its idle
    level ([rst_n] excluded — reset sequencing belongs to the test). *)
val drive_idle : Bits.t ref I.t -> unit

(** [create ?read_cycles ?write_cycles ?icache ?lines_log2 ?write_update ?video ?fast_mul ?mul_stages i]
    wires the board SoC, booting the design ROM {!Risc5.Rom.bootloader}, to the full-size
    PSRAM model ([addr_bits] 19 — the gates load the real disk image into low RAM). It is
    {!Nexys4_board.Soc.For_tests.Tb.create} with those two knobs pinned; every other knob
    forwards. [read_cycles] / [write_cycles] default to 2 (the model answers at once, so
    small waits exercise only the controller FSM — the checkpoint's regime; the visual
    golden passes 5 to match the board). The cache knobs ([icache] / [lines_log2] /
    [write_update]) and [fast_mul] / [mul_stages] (all default off) forward to
    {!Nexys4_board.Soc.create} — for the bench's sweeps; the tests leave them off. [sclk]
    is the only output read directly; everything else is reached by name under
    [Cyclesim.Config.trace_all]. *)
val create
  :  ?clocks_per_ms:int
       (** forwards to {!Nexys4_board.Soc.create} (the ms-timer prescaler) *)
  -> ?read_cycles:int
  -> ?write_cycles:int
  -> ?icache:bool
  -> ?lines_log2:int
  -> ?write_update:bool
       (** default [false]; [true] = the Phase-10b write-update snoop policy (word
           store-hits refresh the cached line in place — see {!Nexys4_board.Cache}) *)
  -> ?video:bool
       (** default [true]; [false] gates the video DMA off the PSRAM port — the
           framebuffer-in-BRAM counterfactual (see {!Nexys4_board.Soc.create}) *)
  -> ?fb_bram:bool
       (** default [false]; [true] = Phase-10c: video served from the
           {!Nexys4_board.Framebuf} BRAM shadow, PSRAM video port tied off (see
           {!Nexys4_board.Soc.create}) *)
  -> ?halftone:bool
       (** default [false]; [true] = feat/halftone v2: instantiate the
           {!Nexys4_board.Halftone} display mode, claim-muxed against Framebuf per request
           (see {!Nexys4_board.Soc.create}) *)
  -> ?write_buffer:bool
       (** default [false]; [true] = Phase-10d: 1-entry write buffer in
           {!Nexys4_board.Cellram} — stores retire in one ce cycle, the write drains in
           the background (see {!Nexys4_board.Cellram.create}) *)
  -> ?wbuf_depth:int
       (** write-buffer FIFO depth 1..4 (default 1; see {!Nexys4_board.Cellram.create}) *)
  -> ?fast_mul:bool
  -> ?mul_stages:int
  -> ?spi_slow_div_log2:int
       (** forwards to {!Nexys4_board.Soc.create}: the slow SPI divider depth (default 6 =
           SPI.v's clk÷64; the gates' SPI_DIV_LOG2=2 turbo knob passes 2 = clk÷4) *)
  -> Signal.t I.t
  -> Signal.t O.t

(** [read_word ~cram_lo ~cram_hi w] reconstructs 32-bit word [w] from the model's two
    8-bit lanes: halfword [2w] = low 16 bits, [2w+1] = high 16 bits; within each,
    [cram_lo] = byte [7:0], [cram_hi] = byte [15:8]. *)
val read_word : cram_lo:Cyclesim.Memory.t -> cram_hi:Cyclesim.Memory.t -> int -> int

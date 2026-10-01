(** Shared board-SoC test harness: {!Nexys4_board.Soc} closed with the behavioural PSRAM
    double {!Nexys4_board.Cellram_model} on its memory pins — the common wiring of the
    board boot checkpoint, the board visual golden, and bench_boot (all this dir). *)

open Hardcaml
module I = Nexys4_board.Soc.For_tests.Tb.I
module O = Nexys4_board.Soc.For_tests.Tb.O

(** [drive_idle inp] = {!Nexys4_board.Soc.For_tests.drive_idle}: every input to its idle
    level ([rst_n] excluded — reset sequencing belongs to the test). *)
val drive_idle : Bits.t ref I.t -> unit

(** [create c i] wires the board SoC in configuration [c], booting the design ROM
    {!Risc5.Rom.bootloader}, to the full-size PSRAM model ([addr_bits] 19 — the gates load
    the real disk image into low RAM): {!Nexys4_board.Soc.For_tests.Tb.create} with those
    two pinned. [?video] and [?datasheet_chip] forward — the gates hold the chip model to
    the datasheet when they boot {!config_of_env}. [sclk] and [rgb] are the outputs read
    directly; everything else is reached by name under [Cyclesim.Config.trace_all]. *)
val create
  :  ?video:bool
  -> ?datasheet_chip:bool
  -> Nexys4_board.Build_config.t
  -> Signal.t I.t
  -> Signal.t O.t

(** {!Nexys4_board.Build_config.shipped} with the gates' environment overrides applied —
    controls for bisecting a failure or running an A/B, never needed for the default run:
    [ICACHE] / [WRITE_UPDATE] / [FB_BRAM] / [HALFTONE] / [FAST_MUL] (each [0] or [1];
    [FAST_MUL=0] = the iterative multipliers), [LINES_LOG2], [MUL_STAGES] (the DSP
    multipliers' pipeline depth), [WBUF] ([0] = no write buffer, [n] = depth n),
    [READ_CYCLES] / [WRITE_CYCLES] (the PSRAM phase lengths) and [SPI_DIV_LOG2] (the
    boot-speed knob). Anything unparsable, or [MUL_STAGES] without the DSP multipliers,
    fails loudly. *)
val config_of_env : unit -> Nexys4_board.Build_config.t

(** [read_word ~cram_lo ~cram_hi w] reconstructs 32-bit word [w] from the model's two
    8-bit lanes: halfword [2w] = low 16 bits, [2w+1] = high 16 bits; within each,
    [cram_lo] = byte [7:0], [cram_hi] = byte [15:8]. *)
val read_word : cram_lo:Cyclesim.Memory.t -> cram_hi:Cyclesim.Memory.t -> int -> int

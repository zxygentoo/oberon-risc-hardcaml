(** Shared board-SoC test harness: {!Nexys4_board.Soc_board} closed with the behavioural
    PSRAM double {!Nexys4_board.Cellram_model} on its memory pins — the common wiring of
    the board boot checkpoint and the board visual golden (bench_boot does the same wiring
    and could adopt it too). *)

open Hardcaml

module I : sig
  type 'a t =
    { clock : 'a
    ; pclk : 'a
    ; rst_n : 'a
    ; miso : 'a
    ; rxd : 'a
    ; btn : 'a
    ; sw : 'a
    ; gpio_in : 'a
    ; ps2c : 'a
    ; ps2d : 'a
    ; msclk : 'a
    ; msdat : 'a
    }
  [@@deriving hardcaml]
end

module O : sig
  type 'a t =
    { sclk : 'a (** SPI clock — the one output the harness drives the SD bridge from *) }
  [@@deriving hardcaml]
end

(** [create ?read_cycles ?write_cycles ?icache ?contents i] wires the board SoC to the
    PSRAM model. [contents] defaults to the design ROM {!Risc5.Rom.bootloader};
    [read_cycles] / [write_cycles] default to 2 (the model answers at once, so small waits
    exercise only the controller FSM — the checkpoint's regime; the visual golden passes 5
    to match the board). [sclk] is the only output read directly; everything else is
    reached by name under [Cyclesim.Config.trace_all]. *)
val create
  :  ?read_cycles:int
  -> ?write_cycles:int
  -> ?icache:bool
  -> ?contents:int array
  -> Signal.t I.t
  -> Signal.t O.t

(** [read_word ~cram_lo ~cram_hi w] reconstructs 32-bit word [w] from the model's two
    8-bit lanes: halfword [2w] = low 16 bits, [2w+1] = high 16 bits; within each,
    [cram_lo] = byte [7:0], [cram_hi] = byte [15:8]. *)
val read_word : cram_lo:Cyclesim.Memory.t -> cram_hi:Cyclesim.Memory.t -> int -> int

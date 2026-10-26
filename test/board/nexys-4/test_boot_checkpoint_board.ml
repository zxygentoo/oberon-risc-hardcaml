(* The boot-handoff checkpoint through the board SoC: the same boot and the same
   comparison as test/boot/test_boot_checkpoint.ml, with the core on a clock enable and
   main memory behind {!Nexys4_board.Cellram} and the chip model. A pass says that the
   freeze during memory waits, the 16/32-bit conversion, the one-cycle path for ROM and
   MMIO, and the arbitration between CPU and video leave the booting machine in the same
   state. *)

open Hardcaml
module Sim = Cyclesim.With_interface (Board_tb.I) (Board_tb.O)

(* a PSRAM boot takes several times the cycles of the single-cycle-RAM one *)
let soc_cycle_cap = 80_000_000

(* [create] is the board SoC + PSRAM model in one configuration. *)
let run_soc_to_handoff create () =
  let sim = Sim.create ~config:Cyclesim.Config.trace_all create in
  let inp = Cyclesim.inputs sim
  and outp = Cyclesim.outputs sim in
  let lo = Bits.of_unsigned_int ~width:1 0
  and hi = Bits.of_unsigned_int ~width:1 1 in
  Boot.Tb.run_to_handoff
    ~sim
    ~miso:inp.miso
    ~sclk:outp.sclk
    ~reset:(fun () ->
      Board_tb.drive_idle inp;
      inp.rst_n := lo;
      Cyclesim.cycle sim;
      inp.rst_n := hi)
    ~cap:soc_cycle_cap
    ~ram:(fun () ->
      let cram_lo = Boot.Tb.lookup_mem sim "cram_lo"
      and cram_hi = Boot.Tb.lookup_mem sim "cram_hi" in
      fun w -> Board_tb.read_word ~cram_lo ~cram_hi w)
    ()
;;

(* Two passes. The bare controller first ({!Nexys4_board.Build_config.bare}: 2 read/write
   cycles, no cache, no buffer, against a chip that answers at once) — the wait-state
   freeze, the 16↔32 conversion, the on-chip fast path and the CPU/video arbiter on their
   own. Then the configuration the bitstream ships (cache, write buffer, framebuffer
   shadow, DSP multiplies, the board's wait counts — {!Board_tb.config_of_env},
   overridable for bisecting), against the chip held to its datasheet. *)
let () =
  let bare =
    let b = Nexys4_board.Build_config.bare in
    match Sys.getenv_opt "SPI_DIV_LOG2" with
    | None -> b
    | Some n -> { b with spi_slow_div_log2 = int_of_string n }
  in
  Printf.printf "── bare PSRAM controller ──\n%!";
  Boot.Checkpoint.run
    ~run_soc_to_handoff:(run_soc_to_handoff (Board_tb.create bare))
    ~pass_msg:
      "CHECKPOINT (BOARD/PSRAM) PASS — Soc boots the real disk to the OS handoff through \
       the Cellram controller; loaded image + architectural state match the oracle, \
       modulo the ROM code-address skew.";
  let cfg = Board_tb.config_of_env () in
  Printf.printf
    "── %s configuration ──\n  %s\n%!"
    (if cfg = Nexys4_board.Build_config.shipped then "shipped" else "overridden")
    (Nexys4_board.Build_config.to_string cfg);
  Boot.Checkpoint.run
    ~run_soc_to_handoff:(run_soc_to_handoff (Board_tb.create ~datasheet_chip:true cfg))
    ~pass_msg:
      "CHECKPOINT (BOARD/configured) PASS — the same handoff state through the full \
       memory stack."
;;

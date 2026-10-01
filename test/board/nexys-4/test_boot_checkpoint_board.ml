(* Phase 7 — boot-handoff checkpoint through the PSRAM board SoC (AGENT.md §6 layer 5, the
   board memory path).

   The Phase-5 checkpoint (test_boot_checkpoint.ml) proven against the PSRAM memory path:
   boot the board SoC — the core on a clock-enable, main memory behind
   {!Nexys4_board.Cellram} driving a behavioural {!Nexys4_board.Cellram_model} — from the
   real disk to the OS handoff, and compare the loaded image + architectural state to the
   oracle, exactly as the BRAM checkpoint does. If this passes, the wait-state freeze, the
   16↔32 width conversion, the on-chip fast path and the CPU/video arbiter are all
   functionally correct: the booting machine reaches the same state.

   The SoC + PSRAM-model wiring is the shared {!Board_tb}; the drive-to-handoff is
   {!Boot_tb}; disk / oracle / §8 compare are {!Boot_checkpoint_common}. Here we supply
   only the board sim, its reset preamble, and the loaded-image read via the model's two
   byte lanes ([Board_tb.read_word]). Small wait counts (the model answers at once; only
   the FSM control flow is under test). *)

open Hardcaml
module Sim = Cyclesim.With_interface (Board_tb.I) (Board_tb.O)

(* PSRAM boot is several× the BRAM cycle count (each RAM access is multi-cycle), so a
   larger safety cap; the run prints the actual handoff cycle. *)
let soc_cycle_cap = 80_000_000

(* [create] is the board SoC + PSRAM model in one configuration. *)
let run_soc_to_handoff create () =
  let sim = Sim.create ~config:Cyclesim.Config.trace_all create in
  let inp = Cyclesim.inputs sim
  and outp = Cyclesim.outputs sim in
  let lo = Bits.of_unsigned_int ~width:1 0
  and hi = Bits.of_unsigned_int ~width:1 1 in
  Boot_tb.run_to_handoff
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
      let cram_lo = Boot_tb.lookup_mem sim "cram_lo"
      and cram_hi = Boot_tb.lookup_mem sim "cram_hi" in
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
  Boot_checkpoint_common.run
    ~run_soc_to_handoff:(run_soc_to_handoff (Board_tb.create bare))
    ~pass_msg:
      "CHECKPOINT (BOARD/PSRAM) PASS — Soc boots the real disk to the OS handoff through \
       the Cellram controller; loaded image + architectural state match the oracle, \
       modulo the §8 code-address skew.";
  let cfg = Board_tb.config_of_env () in
  Printf.printf
    "── %s configuration ──\n  %s\n%!"
    (if cfg = Nexys4_board.Build_config.shipped then "shipped" else "overridden")
    (Nexys4_board.Build_config.to_string cfg);
  Boot_checkpoint_common.run
    ~run_soc_to_handoff:(run_soc_to_handoff (Board_tb.create ~datasheet_chip:true cfg))
    ~pass_msg:
      "CHECKPOINT (BOARD/configured) PASS — the same handoff state through the full \
       memory stack."
;;

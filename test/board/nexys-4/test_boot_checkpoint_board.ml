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

let run_soc_to_handoff () =
  (* board SoC + PSRAM model at the checkpoint's small wait counts (Board_tb defaults: 2
     read/write cycles, cache off, ROM = Risc5.Rom). *)
  let sim = Sim.create ~config:Cyclesim.Config.trace_all (fun i -> Board_tb.create i) in
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

let () =
  Boot_checkpoint_common.run
    ~run_soc_to_handoff
    ~pass_msg:
      "CHECKPOINT (BOARD/PSRAM) PASS — Soc boots the real disk to the OS handoff through \
       the Cellram controller; loaded image + architectural state match the oracle, \
       modulo the §8 code-address skew."
;;

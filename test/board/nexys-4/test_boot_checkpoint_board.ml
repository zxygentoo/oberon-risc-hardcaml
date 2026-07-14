(* Phase 7 — boot-handoff checkpoint through the PSRAM board SoC (AGENT.md §6 layer 5, the
   board memory path).

   The Phase-5 checkpoint (test_boot_checkpoint.ml) proven against the PSRAM memory path:
   boot the board SoC — the core on a clock-enable, main memory behind
   {!Nexys4_board.Cellram} driving a behavioural {!Nexys4_board.Cellram_model} — from the
   real disk to the OS handoff, and compare the loaded image + architectural state to the
   oracle, exactly as the BRAM checkpoint does. If this passes, the wait-state freeze, the
   16↔32 width conversion, the on-chip fast path and the CPU/video arbiter are all
   functionally correct: the booting machine reaches the same state.

   The SoC + PSRAM-model wiring is the shared {!Board_tb}; the SoC-independent half (disk,
   oracle boot, §8-aware compare, the [run] driver) is shared with the BRAM checkpoint in
   {!Boot_checkpoint_common}. Here we only drive the SD card and read the loaded image
   back by reconstructing 32-bit words from the model's two byte lanes
   ([Board_tb.read_word]). Small wait counts (the model answers at once; only the FSM
   control flow is under test). *)

open Hardcaml
open Boot_checkpoint_common
module Sim = Cyclesim.With_interface (Board_tb.I) (Board_tb.O)

(* PSRAM boot is several× the BRAM cycle count (each RAM access is multi-cycle), so a
   larger safety cap; the run prints the actual handoff cycle. *)
let soc_cycle_cap = 80_000_000

let run_soc_to_handoff () =
  let tmp = copy_to_temp disk_image in
  let bridge = Sd_bridge.create (Emu.Disk.to_spi (Emu.Disk.create (Some tmp))) in
  (* board SoC + PSRAM model at the checkpoint's small wait counts (Board_tb defaults: 2
     read/write cycles, cache off, ROM = Risc5.Rom). *)
  let sim = Sim.create ~config:Cyclesim.Config.trace_all (fun i -> Board_tb.create i) in
  let inp = Cyclesim.inputs sim
  and outp = Cyclesim.outputs sim in
  let some w = function
    | Some x -> x
    | None -> failwith ("lookup: " ^ w ^ " not found")
  in
  let reg n = some n (Cyclesim.lookup_reg_by_name sim n) in
  let read n = Cyclesim.Reg.to_int (reg n) in
  let pc = reg "pc"
  and rdy = reg "rdy"
  and shreg = reg "spi_shreg"
  and spi_ctrl = reg "spi_ctrl" in
  let lo = Bits.of_unsigned_int ~width:1 0
  and hi = Bits.of_unsigned_int ~width:1 1 in
  (* drive the idle levels for the unused serial / open-drain lines *)
  inp.rxd := hi;
  inp.ps2c := hi;
  inp.ps2d := hi;
  inp.msclk := hi;
  inp.msdat := hi;
  inp.rst_n := lo;
  inp.miso := hi;
  Cyclesim.cycle sim;
  inp.rst_n := hi;
  let cycle = ref 0
  and handoff = ref false in
  while (not !handoff) && !cycle < soc_cycle_cap do
    inp.miso := if Sd_bridge.miso bridge = 1 then hi else lo;
    Cyclesim.cycle sim;
    let ctrl = Cyclesim.Reg.to_int spi_ctrl in
    Sd_bridge.step
      bridge
      ~sclk:(Bits.to_unsigned_int !(outp.sclk))
      ~rdy:(Cyclesim.Reg.to_int rdy)
      ~data_tx:(Cyclesim.Reg.to_int shreg)
      ~fast:((ctrl lsr 2) land 1 = 1)
      ~selected:(ctrl land 3 = 1);
    if Cyclesim.Reg.to_int pc < rom_region_base then handoff := true;
    incr cycle
  done;
  rm_temp tmp;
  if not !handoff
  then (
    Printf.printf
      "NO HANDOFF in %d cycles (pc=0x%X spi_bytes=%d)\n"
      soc_cycle_cap
      (read "pc")
      (Sd_bridge.nbytes bridge);
    None)
  else (
    Printf.printf
      "HANDOFF at cycle %d → pc=0x%X (spi_bytes=%d)\n%!"
      !cycle
      (read "pc")
      (Sd_bridge.nbytes bridge);
    let regfile = some "regfile" (Cyclesim.lookup_mem_by_name sim "regfile") in
    let cram_lo = some "cram_lo" (Cyclesim.lookup_mem_by_name sim "cram_lo") in
    let cram_hi = some "cram_hi" (Cyclesim.lookup_mem_by_name sim "cram_hi") in
    Some
      { pc = read "pc"
      ; regs = Array.init 16 (fun k -> Cyclesim.Memory.to_int regfile ~address:k)
      ; flags = read "z" lor (read "n" lsl 1) lor (read "c" lsl 2) lor (read "ov" lsl 3)
      ; h = read "h"
      ; ram = (fun w -> Board_tb.read_word ~cram_lo ~cram_hi w)
      })
;;

let () =
  run
    ~run_soc_to_handoff
    ~pass_msg:
      "CHECKPOINT (BOARD/PSRAM) PASS — Soc boots the real disk to the OS handoff through \
       the Cellram controller; loaded image + architectural state match the oracle, \
       modulo the §8 code-address skew."
;;

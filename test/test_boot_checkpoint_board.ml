(* Phase 7 — boot-handoff checkpoint through the PSRAM board SoC (AGENT.md §6 layer 5, the
   board memory path).

   The Phase-5 checkpoint (test_boot_checkpoint.ml) proven against the PSRAM memory path:
   boot {!Nexys4_board.Soc_board} — the core on a clock-enable, main memory behind
   {!Nexys4_board.Cellram} driving a behavioural {!Nexys4_board.Cellram_model} — from the
   real disk to the OS handoff, and compare the loaded image + architectural state to the
   oracle, exactly as the BRAM checkpoint does. If this passes, the wait-state freeze, the
   16↔32 width conversion, the on-chip fast path and the CPU/video arbiter are all
   functionally correct: the booting machine reaches the same state.

   The SoC-independent half (disk, oracle boot, §8-aware compare, the [run] driver) is
   shared with the BRAM checkpoint in {!Boot_checkpoint_common}; here we supply only the
   board SoC wrapped with the chip model on its PSRAM pins, and read the loaded image back
   by reconstructing 32-bit words from the model's two 8-bit halfword lanes
   ([cram_lo]/[cram_hi]) rather than the BRAM's four byte lanes. Small wait counts (the
   model answers at once; only the FSM control flow is under test). *)

open Hardcaml
open Boot_checkpoint_common
module Soc_board = Nexys4_board.Soc_board
module Cellram_model = Nexys4_board.Cellram_model

(* The board SoC closed with the behavioural cellular-RAM on its pins. Inputs are the
   SoC's minus [mem_dq_i] (driven by the model); the only output the harness reads
   directly is [sclk] (for the SD bridge) — everything else is reached by name via
   [trace_all]. *)
module Tb = struct
  module I = struct
    type 'a t =
      { clock : 'a
      ; pclk : 'a [@bits 1]
      ; rst_n : 'a [@bits 1]
      ; miso : 'a [@bits 1]
      ; rxd : 'a [@bits 1]
      ; btn : 'a [@bits 4]
      ; sw : 'a [@bits 8]
      ; gpio_in : 'a [@bits 8]
      ; ps2c : 'a [@bits 1]
      ; ps2d : 'a [@bits 1]
      ; msclk : 'a [@bits 1]
      ; msdat : 'a [@bits 1]
      }
    [@@deriving hardcaml]
  end

  module O = struct
    type 'a t = { sclk : 'a [@bits 1] } [@@deriving hardcaml]
  end

  let create ~contents (i : _ I.t) : _ O.t =
    let dq = Signal.wire 16 in
    let soc =
      Soc_board.create
        ~contents
        ~read_cycles:2
        ~write_cycles:2
        { Soc_board.I.clock = i.clock
        ; pclk = i.pclk
        ; rst_n = i.rst_n
        ; miso = i.miso
        ; rxd = i.rxd
        ; btn = i.btn
        ; sw = i.sw
        ; gpio_in = i.gpio_in
        ; ps2c = i.ps2c
        ; ps2d = i.ps2d
        ; msclk = i.msclk
        ; msdat = i.msdat
        ; mem_dq_i = dq
        }
    in
    let m =
      Cellram_model.create
        { Cellram_model.I.clock = i.clock
        ; mem_adr = soc.mem_adr
        ; mem_dq_o = soc.mem_dq_o
        ; ce_n = soc.ram_ce_n
        ; we_n = soc.ram_we_n
        ; ub_n = soc.ram_ub_n
        ; lb_n = soc.ram_lb_n
        }
    in
    Signal.assign dq m.mem_dq_i;
    { O.sclk = soc.sclk }
  ;;
end

module Sim = Cyclesim.With_interface (Tb.I) (Tb.O)

(* PSRAM boot is several× the BRAM cycle count (each RAM access is multi-cycle), so a
   larger safety cap; the run prints the actual handoff cycle. *)
let soc_cycle_cap = 80_000_000

let run_soc_to_handoff () =
  let tmp = copy_to_temp disk_image in
  let bridge = Sd_bridge.create (Oracle.Disk.to_spi (Oracle.Disk.create (Some tmp))) in
  let sim =
    Sim.create
      ~config:Cyclesim.Config.trace_all
      (Tb.create ~contents:Oracle.Boot_rom.bootloader)
  in
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
    (* reconstruct a 32-bit word from the model's two halfword byte lanes: halfword 2w =
       low 16 bits, halfword 2w+1 = high 16 bits; within each, cram_lo = byte [7:0],
       cram_hi = byte [15:8]. *)
    let cram_lo = some "cram_lo" (Cyclesim.lookup_mem_by_name sim "cram_lo") in
    let cram_hi = some "cram_hi" (Cyclesim.lookup_mem_by_name sim "cram_hi") in
    Some
      { pc = read "pc"
      ; regs = Array.init 16 (fun k -> Cyclesim.Memory.to_int regfile ~address:k)
      ; flags = read "z" lor (read "n" lsl 1) lor (read "c" lsl 2) lor (read "ov" lsl 3)
      ; h = read "h"
      ; ram =
          (fun w ->
            let bl k = Cyclesim.Memory.to_int cram_lo ~address:k in
            let bh k = Cyclesim.Memory.to_int cram_hi ~address:k in
            bl (2 * w)
            lor (bh (2 * w) lsl 8)
            lor (bl ((2 * w) + 1) lsl 16)
            lor (bh ((2 * w) + 1) lsl 24))
      })
;;

let () =
  run
    ~run_soc_to_handoff
    ~pass_msg:
      "CHECKPOINT (BOARD/PSRAM) PASS — Soc_board boots the real disk to the OS handoff \
       through the Cellram controller; loaded image + architectural state match the \
       oracle, modulo the §8 code-address skew."
;;

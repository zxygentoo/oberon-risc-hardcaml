(* Phase 5 — boot-handoff checkpoint (AGENT.md §6 layer 5).

   Boot the minimal SoC from the real disk image — with the SD card modelled test-side by
   a bit-level SPI slave over [Oracle.Disk] — to the OS handoff (pc leaves the boot ROM
   for low RAM), then compare the loaded image + architectural state against the oracle
   booting the same [.dsk]. They agree exactly, modulo the §8 code-address skew (which
   self-heals in low RAM): the static loaded image is byte-identical; only runtime
   pc-links (R15, boot-stack saved links) carry the constant ROM-base offset.

   The SoC-independent half — the disk, the oracle boot, the §8-aware compare, the [run]
   driver — is shared with the board checkpoint in {!Boot_checkpoint_common}; here we
   supply only the BRAM SoC's Cyclesim and its four-byte-lane RAM read. The SD card is the
   shared {!Sd_bridge}. *)

open Hardcaml
open Boot_checkpoint_common
module Soc = Risc5.Soc
module Sim = Cyclesim.With_interface (Soc.I) (Soc.O)

let soc_cycle_cap = 30_000_000

(* Boot our SoC from the disk to the OS handoff; [Some snapshot] there, [None] if it never
   leaves the ROM within the cycle cap. *)
let run_soc_to_handoff () =
  let tmp = copy_to_temp disk_image in
  let bridge = Sd_bridge.create (Oracle.Disk.to_spi (Oracle.Disk.create (Some tmp))) in
  let sim =
    Sim.create
      ~config:Cyclesim.Config.trace_all
      (Soc.create ~contents:Risc5.Rom.bootloader)
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
  and shreg = reg "spi_shreg" (* SoC-unique: UART/PS2 shift regs are also "shreg" *)
  and spi_ctrl = reg "spi_ctrl" in
  let lo = Bits.of_unsigned_int ~width:1 0
  and hi = Bits.of_unsigned_int ~width:1 1 in
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
    let lanes =
      Array.init 4 (fun k ->
        let n = Printf.sprintf "ram%d" k in
        some n (Cyclesim.lookup_mem_by_name sim n))
    in
    Some
      { pc = read "pc"
      ; regs = Array.init 16 (fun k -> Cyclesim.Memory.to_int regfile ~address:k)
      ; flags = read "z" lor (read "n" lsl 1) lor (read "c" lsl 2) lor (read "ov" lsl 3)
      ; h = read "h"
      ; ram =
          (fun w ->
            let b k = Cyclesim.Memory.to_int lanes.(k) ~address:w in
            (b 3 lsl 24) lor (b 2 lsl 16) lor (b 1 lsl 8) lor b 0)
      })
;;

let () =
  run
    ~run_soc_to_handoff
    ~pass_msg:
      "CHECKPOINT PASS — SoC boots the real disk to the OS handoff (pc=0); loaded image \
       + architectural state match the oracle, modulo the §8 code-address skew."
;;

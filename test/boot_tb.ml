(* Public API in [boot_tb.mli]. The Cyclesim-side half shared by the four boot gates: loud
   by-name lookups, the SPI/SD-card tick, and the run-to-handoff driver. It is
   SoC-independent — the BRAM and board SoCs expose the same register/memory names (pc,
   rdy, spi_shreg, spi_ctrl, regfile, z/n/c/ov/h); only sim construction, the reset
   preamble, and the RAM readback differ, and those come in as closures. The Hardcaml-free
   half (disk, oracle boots, §8 compare, fb machinery) is [Boot_checkpoint_common]. *)

open Hardcaml
module BCC = Boot_checkpoint_common

let some what = function
  | Some x -> x
  | None -> failwith ("lookup: " ^ what ^ " not found")
;;

let lookup_reg sim n = some n (Cyclesim.lookup_reg_by_name sim n)
let lookup_mem sim n = some n (Cyclesim.lookup_mem_by_name sim n)

(* the packed N/Z/C/OV flags word, as the oracle reads it *)
let flags_word sim =
  let r n = Cyclesim.Reg.to_int (lookup_reg sim n) in
  r "z" lor (r "n" lsl 1) lor (r "c" lsl 2) lor (r "ov" lsl 3)
;;

let hi = Bits.of_unsigned_int ~width:1 1
let lo = Bits.of_unsigned_int ~width:1 0

module Spi = struct
  type t =
    { bridge : Sd_bridge.t
    ; miso : Bits.t ref
    ; sclk : Bits.t ref
    ; rdy : Cyclesim.Reg.t
    ; shreg : Cyclesim.Reg.t
    ; ctrl : Cyclesim.Reg.t
    }

  let attach sim ~miso ~sclk bridge =
    { bridge
    ; miso
    ; sclk
    ; rdy = lookup_reg sim "rdy"
    ; shreg =
        lookup_reg sim "spi_shreg" (* SoC-unique: UART/PS2 shregs are also "shreg" *)
    ; ctrl = lookup_reg sim "spi_ctrl"
    }
  ;;

  (* one sim cycle with the SD card on the wire: present miso, cycle, then advance the
     bridge on the cycle's outputs (whole-value exchange begins on rdy's falling edge —
     see Sd_bridge) *)
  let tick sim t =
    t.miso := if Sd_bridge.miso t.bridge = 1 then hi else lo;
    Cyclesim.cycle sim;
    let ctrl = Cyclesim.Reg.to_int t.ctrl in
    Sd_bridge.step
      t.bridge
      ~sclk:(Bits.to_unsigned_int !(t.sclk))
      ~rdy:(Cyclesim.Reg.to_int t.rdy)
      ~data_tx:(Cyclesim.Reg.to_int t.shreg)
      ~fast:((ctrl lsr 2) land 1 = 1)
      ~selected:(ctrl land 3 = 1)
  ;;
end

(* Boot a SoC sim from the real disk to the OS handoff (pc leaves the ROM-decode region):
   the shared body of both checkpoints' [run_soc_to_handoff]. [reset] runs the gate's own
   reset preamble; [ram] builds the snapshot's word reader (called only at the handoff, so
   its lookups stay off the boot path). *)
let run_to_handoff ~sim ~miso ~sclk ~reset ~cap ~ram () =
  let tmp = BCC.copy_to_temp BCC.disk_image in
  let bridge = Sd_bridge.create (Emu.Disk.to_spi (Emu.Disk.create (Some tmp))) in
  let spi = Spi.attach sim ~miso ~sclk bridge in
  let pc = lookup_reg sim "pc" in
  reset ();
  let cycle = ref 0
  and handoff = ref false in
  while (not !handoff) && !cycle < cap do
    Spi.tick sim spi;
    if Cyclesim.Reg.to_int pc < BCC.rom_region_base then handoff := true;
    incr cycle
  done;
  BCC.rm_temp tmp;
  let read n = Cyclesim.Reg.to_int (lookup_reg sim n) in
  if not !handoff
  then (
    Printf.printf
      "NO HANDOFF in %d cycles (pc=0x%X spi_bytes=%d)\n"
      cap
      (read "pc")
      (Sd_bridge.nbytes bridge);
    None)
  else (
    Printf.printf
      "HANDOFF at cycle %d → pc=0x%X (spi_bytes=%d)\n%!"
      !cycle
      (read "pc")
      (Sd_bridge.nbytes bridge);
    let regfile = lookup_mem sim "regfile" in
    Some
      { BCC.pc = read "pc"
      ; regs = Array.init 16 (fun k -> Cyclesim.Memory.to_int regfile ~address:k)
      ; flags = flags_word sim
      ; h = read "h"
      ; ram = ram ()
      })
;;

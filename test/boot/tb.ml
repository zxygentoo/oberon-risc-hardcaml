(* Public API in [tb.mli]. The Cyclesim-side half shared by the four boot gates: loud
   by-name lookups, the SPI/SD-card tick, and the run-to-handoff driver. It is
   SoC-independent — the BRAM and board SoCs expose the same register/memory names (pc,
   rdy, spi_shreg, spi_ctrl, regfile, z/n/c/ov/h); only sim construction, the reset
   preamble, and the RAM readback differ, and those come in as closures. The Hardcaml-free
   halves are [Disk], [Oracle], [Checkpoint] and [Golden]. *)

open Hardcaml

(* a SoC word pc below this left the ROM-decode region (0x3FF000..0x3FFFFF) for low RAM *)
let rom_region_base = 0x3F_F000

let some what = function
  | Some x -> x
  | None -> failwith ("lookup: " ^ what ^ " not found")
;;

let lookup_reg sim n = some n (Cyclesim.lookup_reg_by_name sim n)
let lookup_mem sim n = some n (Cyclesim.lookup_mem_by_name sim n)

(* node-or-reg: plain lookup_node_by_name misses registers (AGENT.md §6) *)
let lookup_node sim n = some n (Cyclesim.lookup_node_or_reg_by_name sim n)

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

  (* present the card's miso for the coming edge *)
  let set_miso t = t.miso := if Sd_bridge.miso t.bridge = 1 then hi else lo

  (* advance the bridge on the settled post-edge state (whole-value exchange begins on
     rdy's falling edge — see Sd_bridge) *)
  let step t =
    let ctrl = Cyclesim.Reg.to_int t.ctrl in
    Sd_bridge.step
      t.bridge
      ~sclk:(Bits.to_unsigned_int !(t.sclk))
      ~rdy:(Cyclesim.Reg.to_int t.rdy)
      ~data_tx:(Cyclesim.Reg.to_int t.shreg)
      ~fast:((ctrl lsr 2) land 1 = 1)
      ~selected:(ctrl land 3 = 1)
  ;;

  (* one sim cycle with the SD card on the wire; split-phase harnesses (the core co-sim
     capture, core_dump) call [set_miso] / [step] around their own edge instead *)
  let tick sim t =
    set_miso t;
    Cyclesim.cycle sim;
    step t
  ;;
end

(* VID60's raster: 1344 x 806 pixel clocks per frame, 1024 x 768 visible. A visible pixel
   reaches [rgb] one 32-px group after its [hcnt] (the word a group fetches is loaded into
   the shift register at the group's last tick), and scanline [vcnt] shows framebuffer row
   [767 - vcnt] (Oberon's origin is bottom-left). *)
let frame_ticks = 1344 * 806
let pixel_delay = 32

let scan_frame sim ~tick ~rgb =
  let hcnt = lookup_reg sim "hcnt"
  and vcnt = lookup_reg sim "vcnt" in
  let fb = Array.make Golden.fb_words 0
  and stray = ref 0 in
  for _ = 1 to frame_ticks do
    tick ();
    if Bits.to_unsigned_int !rgb <> 0
    then (
      let x = Cyclesim.Reg.to_int hcnt - pixel_delay
      and v = Cyclesim.Reg.to_int vcnt in
      if x >= 0 && x < 32 * Golden.fb_w && v < Golden.fb_h
      then (
        let i = ((Golden.fb_h - 1 - v) * Golden.fb_w) + (x / 32) in
        fb.(i) <- fb.(i) lor (1 lsl (x land 31)))
      else incr stray)
  done;
  fb, !stray
;;

(* Boot a SoC sim from the real disk to the OS handoff (pc leaves the ROM-decode region):
   the shared body of both checkpoints' [run_soc_to_handoff]. [reset] runs the gate's own
   reset preamble; [ram] builds the snapshot's word reader (called only at the handoff, so
   its lookups stay off the boot path). *)
let run_to_handoff ~sim ~miso ~sclk ~reset ~cap ~ram () =
  let tmp = Disk.copy_to_temp Disk.image in
  let bridge = Sd_bridge.create (Emu.Disk.to_spi (Emu.Disk.create (Some tmp))) in
  let spi = Spi.attach sim ~miso ~sclk bridge in
  let pc = lookup_reg sim "pc" in
  reset ();
  let cycle = ref 0
  and handoff = ref false in
  while (not !handoff) && !cycle < cap do
    Spi.tick sim spi;
    if Cyclesim.Reg.to_int pc < rom_region_base then handoff := true;
    incr cycle
  done;
  Disk.rm_temp tmp;
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
      { Checkpoint.pc = read "pc"
      ; regs = Array.init 16 (fun k -> Cyclesim.Memory.to_int regfile ~address:k)
      ; flags = flags_word sim
      ; h = read "h"
      ; ram = ram ()
      })
;;

(* Phase 5 — boot-handoff checkpoint (AGENT.md §6 layer 5).

   Boot the minimal SoC from the real disk image — with the SD card modelled test-side by
   a bit-level SPI slave over [Emu.Disk] — to the OS handoff (pc leaves the boot ROM for
   low RAM), then compare the loaded image + architectural state against the oracle
   booting the same [.dsk]. They agree exactly, modulo the §8 code-address skew (which
   self-heals in low RAM): the static loaded image is byte-identical; only runtime
   pc-links (R15, boot-stack saved links) carry the constant ROM-base offset.

   The shared halves: {!Boot_checkpoint_common} (disk, oracle boot, §8-aware compare, the
   [run] driver) and {!Boot_tb} (the Cyclesim drive to the handoff). Here we supply only
   the BRAM SoC's sim, its reset preamble, and its four-byte-lane RAM read. *)

open Hardcaml
module Soc = Risc5.Soc
module Sim = Cyclesim.With_interface (Soc.I) (Soc.O)

let soc_cycle_cap = 30_000_000

let run_soc_to_handoff () =
  let sim =
    Sim.create
      ~config:Cyclesim.Config.trace_all
      (Soc.create ~contents:Risc5.Rom.bootloader)
  in
  let inp = Cyclesim.inputs sim
  and outp = Cyclesim.outputs sim in
  let lo = Bits.of_unsigned_int ~width:1 0
  and hi = Bits.of_unsigned_int ~width:1 1 in
  Boot_tb.run_to_handoff
    ~sim
    ~miso:inp.miso
    ~sclk:outp.sclk
    ~reset:(fun () ->
      inp.rst_n := lo;
      inp.miso := hi;
      Cyclesim.cycle sim;
      inp.rst_n := hi)
    ~cap:soc_cycle_cap
    ~ram:(fun () ->
      let lanes =
        Array.init 4 (fun k -> Boot_tb.lookup_mem sim (Printf.sprintf "ram%d" k))
      in
      fun w ->
        let b k = Cyclesim.Memory.to_int lanes.(k) ~address:w in
        (b 3 lsl 24) lor (b 2 lsl 16) lor (b 1 lsl 8) lor b 0)
    ()
;;

let () =
  Boot_checkpoint_common.run
    ~run_soc_to_handoff
    ~pass_msg:
      "CHECKPOINT PASS — SoC boots the real disk to the OS handoff (pc=0); loaded image \
       + architectural state match the oracle, modulo the §8 code-address skew."
;;

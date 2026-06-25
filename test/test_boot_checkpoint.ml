(* Phase 5 — boot-handoff checkpoint (AGENT.md §6 layer 5).

   Boot the minimal SoC from the real disk image — with the SD card modelled test-side by
   a bit-level SPI slave over [Oracle.Disk] — to the OS handoff (pc leaves the boot ROM
   for low RAM), then compare the loaded image + architectural state against the oracle
   booting the same [.dsk]. They agree exactly, modulo the §8 code-address skew (which
   self-heals in low RAM): the static loaded image is byte-identical; only runtime
   pc-links (R15, boot-stack saved links) carry the constant ROM-base offset.

   The SD card is the shared {!Sd_bridge} — a faithful off-chip SPI slave over
   [Oracle.Disk] watching the SoC's real [sclk]/[mosi]/[miso] pins. *)

open Hardcaml
module Soc = Risc5.Soc
module R = Oracle.Risc
module Sim = Cyclesim.With_interface (Soc.I) (Soc.O)

(* Locate the project root by walking up for [dune-project], so the disk resolves from any
   cwd — the [@boot_checkpoint] rule (cwd [_build/default/test]) and a bare [dune exec]
   from the repo root alike. The marker sits at both the real root and dune's
   [_build/default] mirror, with the disk at the same [vendor/] offset under each
   (declared as a dep so the rule copies it there). *)
let project_root () =
  let rec up dir =
    if Sys.file_exists (Filename.concat dir "dune-project")
    then dir
    else (
      let parent = Filename.dirname dir in
      if String.equal parent dir
      then
        failwith
          "test_boot_checkpoint: no dune-project found above cwd (project root not \
           located)"
      else up parent)
  in
  up (Sys.getcwd ())
;;

let disk_image =
  Filename.concat
    (project_root ())
    "vendor/oberon-risc-emu-ocaml/DiskImage/Oberon-2020-08-18.dsk"
;;

(* a SoC word pc below this left the ROM-decode region (0x3FF000..0x3FFFFF) for low RAM;
   the oracle's word pc below [oracle_ram_base] (= its mem_size/4) is likewise in low RAM *)
let rom_region_base = 0x3F_F000
let oracle_ram_base = 0x4_0000
let soc_cycle_cap = 30_000_000
let oracle_step_cap = 5_000_000

(* loaded-image compare window: words 0..this. It stops below the MMIO/RAM-alias region —
   our SoC's unconditional SRAM write lands the SPI-data store at byte 0xFFFD0 (word
   0x3FFF4), which the oracle routes to store_io instead; that is the documented aliasing,
   not a load divergence, so it sits outside this window. *)
let loaded_image_words = 0x2_0000

(* §8: code addresses (pc-links) differ by a constant byte offset — the oracle's ROM base
   minus ours — while they point into the boot-ROM frame. A value "reconciles" if it is
   equal, or equal after adding that offset (mod 2^32). A real divergence reconciles under
   neither. *)
let code_offset = 0xFF00_1800
let reconciles hw oracle = hw = oracle || (hw + code_offset) land 0xFFFF_FFFF = oracle

let copy_to_temp src =
  let tmp = Filename.temp_file "checkpoint_" ".dsk" in
  let ic = open_in_bin src
  and oc = open_out_bin tmp in
  output_string oc (really_input_string ic (in_channel_length ic));
  close_in ic;
  close_out oc;
  tmp
;;

let rm_temp tmp =
  try Sys.remove tmp with
  | Sys_error _ -> ()
;;

(* The off-chip SD card (bit-level SPI slave over Oracle.Disk) is the shared {!Sd_bridge}. *)

(* ── A machine's architectural state at the handoff, for differential comparison ── *)
type snapshot =
  { pc : int
  ; regs : int array (* R0..R15 *)
  ; flags : int
  ; h : int
  ; ram : int -> int (* word reader, indices 0..0x3FFFF *)
  }

(* Boot our SoC from the disk to the OS handoff; [Some snapshot] there, [None] if it never
   leaves the ROM within the cycle cap. *)
let run_soc_to_handoff () =
  let tmp = copy_to_temp disk_image in
  let bridge = Sd_bridge.create (Oracle.Disk.to_spi (Oracle.Disk.create (Some tmp))) in
  let sim =
    Sim.create
      ~config:Cyclesim.Config.trace_all
      (Soc.create ~contents:Oracle.Boot_rom.bootloader)
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

(* Boot the OCaml oracle on the same image to its handoff, wired exactly as the frontend
   does (PCLink serial + a no-op clipboard + the disk), the configuration that produced
   the goldens. *)
let boot_oracle_to_handoff () =
  let tmp = copy_to_temp disk_image in
  let oracle = R.make () in
  R.set_serial oracle (Oracle.Pclink.to_serial (Oracle.Pclink.create ()));
  R.set_clipboard
    oracle
    (Oracle.Clipboard.to_clipboard
       (Oracle.Clipboard.create
          { Oracle.Clipboard.get_text = (fun () -> None); set_text = (fun _ -> ()) }));
  R.set_spi oracle 1 (Oracle.Disk.to_spi (Oracle.Disk.create (Some tmp)));
  let steps = ref 0 in
  while R.For_tests.pc oracle >= oracle_ram_base && !steps < oracle_step_cap do
    if !steps land 0xFFF = 0 then R.set_time oracle (Oracle.U32.wrap (!steps / 25000));
    R.For_tests.single_step oracle;
    incr steps
  done;
  rm_temp tmp;
  Printf.printf
    "oracle handoff: pc=0x%X after %d steps\n%!"
    (R.For_tests.pc oracle)
    !steps;
  let ram = R.For_tests.ram oracle in
  { pc = R.For_tests.pc oracle
  ; regs = R.For_tests.regs oracle
  ; flags = R.For_tests.flags oracle
  ; h = R.For_tests.h oracle
  ; ram = (fun w -> ram.(w))
  }
;;

(* Differential compare, §8-aware: every difference must reconcile under [code_offset] (a
   code-address link) or it is a real failure. Prints a summary; returns [true] on pass. *)
let compare_snapshots ~hw ~oracle =
  let fail = ref false in
  let require name cond =
    if not cond
    then (
      fail := true;
      Printf.printf "  FAIL: %s\n" name)
  in
  require "pc" (hw.pc = oracle.pc);
  require "flags" (hw.flags = oracle.flags);
  require "H" (hw.h = oracle.h);
  let skew_regs = ref 0 in
  Array.iteri
    (fun k h ->
      let o = oracle.regs.(k) in
      if h <> o
      then
        if reconciles h o
        then incr skew_regs
        else (
          fail := true;
          Printf.printf
            "  FAIL: R%d hw=0x%X or=0x%X (not a §8 code-address offset)\n"
            k
            h
            o))
    hw.regs;
  let exact = ref 0
  and skew = ref 0
  and real = ref 0
  and first_real = ref (-1) in
  for w = 0 to loaded_image_words - 1 do
    let h = hw.ram w
    and o = oracle.ram w in
    if h = o
    then incr exact
    else if reconciles h o
    then incr skew
    else (
      incr real;
      if !first_real < 0 then first_real := w)
  done;
  if !real > 0
  then (
    fail := true;
    Printf.printf
      "  FAIL: %d loaded-image words diverge (first 0x%X: hw=0x%X or=0x%X)\n"
      !real
      !first_real
      (hw.ram !first_real)
      (oracle.ram !first_real));
  Printf.printf
    "arch: pc/flags/H match; %d reg(s) = §8 code-addr skew (the R15 link)\n"
    !skew_regs;
  Printf.printf
    "loaded image [0..0x%X): %d exact, %d §8-skewed (boot-stack links), %d real diffs\n"
    loaded_image_words
    !exact
    !skew
    !real;
  not !fail
;;

let () =
  match run_soc_to_handoff () with
  | None -> exit 1
  | Some hw ->
    let oracle = boot_oracle_to_handoff () in
    if compare_snapshots ~hw ~oracle
    then
      Printf.printf
        "CHECKPOINT PASS — SoC boots the real disk to the OS handoff (pc=0); loaded \
         image + architectural state match the oracle, modulo the §8 code-address skew.\n"
    else (
      Printf.printf "CHECKPOINT FAIL\n";
      exit 1)
;;

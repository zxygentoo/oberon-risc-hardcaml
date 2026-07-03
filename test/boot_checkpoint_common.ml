(* Public API and behaviour spec live in [boot_checkpoint_common.mli]. The SoC-independent
   half of the boot checkpoint, shared by the BRAM and PSRAM variants: disk + oracle
   boot + §8-aware compare + the [run] driver. The interface-specific [run_soc_to_handoff]
   (the Cyclesim setup + RAM read) lives in each checkpoint. *)

module R = Oracle.Risc

type snapshot =
  { pc : int
  ; regs : int array
  ; flags : int
  ; h : int
  ; ram : int -> int
  }

(* Locate the project root by walking up for [dune-project], so the disk resolves from any
   cwd — the [@boot_checkpoint*] rules (cwd [_build/default/test]) and a bare [dune exec]
   from the repo root alike. (dune does NOT mirror [dune-project] into [_build/default],
   so the walk climbs out of [_build] and lands at the real root every time; the rules'
   declared disk dep is a rebuild trigger, not the copy that gets read.) *)
let project_root () =
  let rec up dir =
    if Sys.file_exists (Filename.concat dir "dune-project")
    then dir
    else (
      let parent = Filename.dirname dir in
      if String.equal parent dir
      then failwith "boot_checkpoint_common: no dune-project found above cwd"
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
let oracle_step_cap = 5_000_000

(* loaded-image compare window: words 0..this. It stops below the MMIO/RAM-alias region —
   the SoC's unconditional RAM write lands the SPI-data store at byte 0xFFFD0 (word
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
  let arch_fail = ref false in
  let require name cond =
    if not cond
    then (
      fail := true;
      arch_fail := true;
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
    "arch: pc/flags/H %s; %d reg(s) = §8 code-addr skew (the R15 link)\n"
    (if !arch_fail then "MISMATCH (see FAIL lines above)" else "match")
    !skew_regs;
  Printf.printf
    "loaded image [0..0x%X): %d exact, %d §8-skewed (boot-stack links), %d real diffs\n"
    loaded_image_words
    !exact
    !skew
    !real;
  not !fail
;;

let run ~run_soc_to_handoff ~pass_msg =
  match run_soc_to_handoff () with
  | None -> exit 1
  | Some hw ->
    let oracle = boot_oracle_to_handoff () in
    if compare_snapshots ~hw ~oracle
    then Printf.printf "%s\n" pass_msg
    else (
      Printf.printf "CHECKPOINT FAIL\n";
      exit 1)
;;

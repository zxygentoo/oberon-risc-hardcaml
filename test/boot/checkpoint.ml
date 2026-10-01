(* Public contract in [checkpoint.mli]. *)

module R = Emu.Risc

type snapshot =
  { pc : int
  ; regs : int array
  ; flags : int
  ; h : int
  ; ram : int -> int
  }

(* the oracle's word pc below this (= its mem_size/4) is in low RAM: its handoff *)
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

(* Boot the OCaml oracle on the same image to its handoff. *)
let boot_oracle_to_handoff () =
  let tmp = Disk.copy_to_temp Disk.image in
  let oracle = Oracle.create ~disk:tmp in
  let steps = ref 0 in
  while R.For_tests.pc oracle >= oracle_ram_base && !steps < oracle_step_cap do
    if !steps land 0xFFF = 0 then R.set_time oracle (Emu.U32.wrap (!steps / 25000));
    R.For_tests.single_step oracle;
    incr steps
  done;
  Disk.rm_temp tmp;
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

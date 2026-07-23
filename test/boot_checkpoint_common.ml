(* Public API and behaviour spec live in [boot_checkpoint_common.mli]. The Hardcaml-free
   half shared by the four boot gates (both checkpoints and both visual goldens): disk +
   oracle boots + §8-aware compare + framebuffer geometry/render/verdict + the loop
   drivers (closure-parameterized, so this module never sees a sim). The Cyclesim-side
   half lives in [Boot_tb]. *)

module R = Emu.Risc

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

(* DISK_IMG overrides (the goldens' historical knob, now uniform across the gates) *)
let disk_image =
  match Sys.getenv_opt "DISK_IMG" with
  | Some p -> p
  | None ->
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
  let tmp = Filename.temp_file "boot_" ".dsk" in
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

(* Wire a fresh oracle exactly as the frontend does (PCLink serial + a no-op clipboard +
   the disk at [disk]) — the configuration that produced the goldens. *)
let make_oracle ~disk =
  let oracle = R.make () in
  R.set_serial oracle (Emu.Pclink.to_serial (Emu.Pclink.create ()));
  R.set_clipboard
    oracle
    (Emu.Clipboard.to_clipboard
       (Emu.Clipboard.create
          { Emu.Clipboard.get_text = (fun () -> None); set_text = (fun _ -> ()) }));
  R.set_spi oracle 1 (Emu.Disk.to_spi (Emu.Disk.create (Some disk)));
  oracle
;;

(* Boot the OCaml oracle on the same image to its handoff. *)
let boot_oracle_to_handoff () =
  let tmp = copy_to_temp disk_image in
  let oracle = make_oracle ~disk:tmp in
  let steps = ref 0 in
  while R.For_tests.pc oracle >= oracle_ram_base && !steps < oracle_step_cap do
    if !steps land 0xFFF = 0 then R.set_time oracle (Emu.U32.wrap (!steps / 25000));
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

(* ─── The visual goldens' shared half (Phase 6b / 10a): framebuffer geometry, the oracle
   framebuffer boot, render/hash, the settle loop, and the verdict ─── *)

let fb_w = 32 (* framebuffer width in 32-px words *)
let fb_h = 768
let fb_words = fb_w * fb_h
let fb_base_word = 0x39FC0 (* display_start 0xE7F00 / 4 *)

(* Boot the oracle as the frontend / test_boot.ml does, advance [frames] at the synthetic
   60 Hz clock, and snapshot the framebuffer + its hash. *)
let boot_oracle_fb ~frames =
  let tmp = copy_to_temp disk_image in
  let risc = make_oracle ~disk:tmp in
  Emu.Headless.run_frames risc frames;
  let fb = Array.init fb_words (fun i -> R.framebuffer_word risc i) in
  let hash = Emu.Headless.framebuffer_hash risc in
  rm_temp tmp;
  fb, hash
;;

let pixel fb ~x ~y = (fb.((y * fb_w) + (x / 32)) lsr (x land 31)) land 1

let popcount fb =
  Array.fold_left
    (fun acc w ->
      let rec pc n a = if n = 0 then a else pc (n lsr 1) (a + (n land 1)) in
      acc + pc (w land 0xFFFFFFFF) 0)
    0
    fb
;;

(* Downsample to ASCII: one char per [sx]x[sy] block, '#' if any pixel in the block is
   set. Rows run top (y high) to bottom (y = 0) since Oberon's origin is bottom-left. *)
let render fb ~sx ~sy =
  let buf = Buffer.create 8192 in
  let y = ref (fb_h - sy) in
  while !y >= 0 do
    for cx = 0 to (1024 / sx) - 1 do
      let set = ref false in
      for dy = 0 to sy - 1 do
        for dx = 0 to sx - 1 do
          if pixel fb ~x:((cx * sx) + dx) ~y:(!y + dy) = 1 then set := true
        done
      done;
      Buffer.add_char buf (if !set then '#' else ' ')
    done;
    Buffer.add_char buf '\n';
    y := !y - sy
  done;
  Buffer.contents buf
;;

(* FNV-1a over the framebuffer words, matching Emu.Headless.framebuffer_hash, so a SoC
   framebuffer hash compares directly to the oracle's. *)
let fb_fnv fb =
  let prime = 0x0000_0100_0000_01b3L
  and offset = 0xcbf2_9ce4_8422_2325L in
  let word h w =
    List.fold_left
      (fun h k ->
        Int64.mul (Int64.logxor h (Int64.of_int ((w lsr (k * 8)) land 0xFF))) prime)
      h
      [ 0; 1; 2; 3 ]
  in
  Array.fold_left word offset fb
;;

(* The goldens' settle loop: run [chunk]-cycle bursts of [tick] and snapshot [read_fb]
   after each, until the framebuffer is drawn (nonzero) and then unchanged for [settle]
   consecutive chunks, or [cap] cycles. [pc]/[spi_bytes] feed the progress line only.
   Returns (last framebuffer, settled?). *)
let run_to_settle ~cap ~chunk ~settle ~tick ~read_fb ~pc ~spi_bytes =
  let cyc = ref 0
  and prev = ref [||]
  and stable = ref 0
  and drawn = ref false in
  while !cyc < cap && !stable < settle do
    for _ = 1 to chunk do
      tick ();
      incr cyc
    done;
    let fb = read_fb () in
    let pop = popcount fb in
    if pop > 0 then drawn := true;
    if !drawn && fb = !prev then incr stable else stable := 0;
    prev := fb;
    Printf.printf
      "  soc @%3dM cyc: pc=0x%X spi=%d pop=%d\n%!"
      (!cyc / 1_000_000)
      (pc ())
      (spi_bytes ())
      pop
  done;
  !prev, !stable >= settle
;;

(* The goldens' verdict: diff the framebuffers word-for-word, render both to ASCII, print
   PASS or FAIL-and-exit. The label parameters reconstruct each golden's exact historical
   lines: [tag] suffixes "VISUAL GOLDEN", [subject] names the machine in the PASS line,
   [render_label] heads the SoC render, [pass_tail] trails the PASS line. *)
let golden_report
  ~tag
  ~subject
  ~render_label
  ~pass_tail
  ~oracle_fb
  ~oracle_hash
  ~soc_fb
  ~soc_hash
  ~settled
  =
  let diffs = ref 0
  and first = ref (-1) in
  Array.iteri
    (fun i w ->
      if w <> oracle_fb.(i)
      then (
        incr diffs;
        if !first < 0 then first := i))
    soc_fb;
  Printf.printf
    "--- ORACLE ---\n%s\n--- %s ---\n%s\n%!"
    (render oracle_fb ~sx:16 ~sy:16)
    render_label
    (render soc_fb ~sx:16 ~sy:16);
  if !diffs = 0 && Int64.equal soc_hash oracle_hash
  then
    Printf.printf
      "VISUAL GOLDEN%s PASS — %s framebuffer byte-identical to the oracle (hash 0x%Lx)%s\n"
      tag
      subject
      oracle_hash
      pass_tail
  else (
    Printf.printf
      "VISUAL GOLDEN%s FAIL: %d/%d framebuffer words differ (first word 0x%X: soc=0x%08X \
       oracle=0x%08X); settled=%b\n"
      tag
      !diffs
      fb_words
      (if !first >= 0 then fb_base_word + !first else 0)
      (if !first >= 0 then soc_fb.(!first) else 0)
      (if !first >= 0 then oracle_fb.(!first) else 0)
      settled;
    exit 1)
;;

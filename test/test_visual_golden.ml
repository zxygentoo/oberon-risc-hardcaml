(* Phase 6b — visual golden (AGENT.md §5/§6).

   Continue the boot PAST the OS handoff and diff the framebuffer (a RAM region) against
   the oracle, rendered to ASCII for eyeballing. The oracle boot is bit-deterministic (its
   [Headless] driver paces a synthetic 60 Hz clock; [test_boot.ml] freezes the same
   hashes) and its idle desktop screen is static, so once both machines have run far
   enough the SoC's framebuffer must match it bit-for-bit (hash 0xb9bdbf56ba51298d, 18607
   px).

   The SoC is much slower per "frame" than the oracle: it bit-bangs the SD card over SPI
   at real timing ({!Sd_bridge}) while the oracle's disk is instant, so the desktop only
   finishes drawing ~32-34M cycles in (vs the oracle's frame 40). Hence the generous cycle
   cap; the run settles once the framebuffer is drawn and then unchanged for [settle]
   chunks.

   Framebuffer: [Risc.default_display_start = 0xE7F00], 1024x768x1bpp = 32x768 = 24576
   words (word i covers 32 horizontal px; Oberon's origin is bottom-left, so we render
   rows top down). Opt-in (boots the real disk): [dune build @visual_golden]; [SOC_CAP]
   overrides the cap, [DISK_IMG] the image. *)

module R = Emu.Risc
open Hardcaml
module Soc = Risc5.Soc
module Sim = Cyclesim.With_interface (Soc.I) (Soc.O)

(* Locate the project root by walking up for [dune-project] (as test_boot_checkpoint
   does), so the disk resolves from any cwd. *)
let project_root () =
  let rec up dir =
    if Sys.file_exists (Filename.concat dir "dune-project")
    then dir
    else (
      let parent = Filename.dirname dir in
      if String.equal parent dir
      then failwith "test_visual_golden: no dune-project found above cwd"
      else up parent)
  in
  up (Sys.getcwd ())
;;

let disk_image =
  match Sys.getenv_opt "DISK_IMG" with
  | Some p -> p
  | None ->
    Filename.concat
      (project_root ())
      "vendor/oberon-risc-emu-ocaml/DiskImage/Oberon-2020-08-18.dsk"
;;

let copy_to_temp src =
  let tmp = Filename.temp_file "visual_" ".dsk" in
  let ic = open_in_bin src
  and oc = open_out_bin tmp in
  output_string oc (really_input_string ic (in_channel_length ic));
  close_in ic;
  close_out oc;
  tmp
;;

let fb_w = 32 (* framebuffer width in 32-px words *)
let fb_h = 768
let fb_words = fb_w * fb_h
let fb_base_word = 0x39FC0 (* display_start 0xE7F00 / 4 *)

(* Boot the oracle exactly as the frontend / test_boot.ml does (PCLink + no-op clipboard +
   disk), advance [frames] at the synthetic 60 Hz clock, and snapshot the framebuffer. *)
let boot_oracle frames =
  let tmp = copy_to_temp disk_image in
  let risc = R.make () in
  R.set_serial risc (Emu.Pclink.to_serial (Emu.Pclink.create ()));
  R.set_clipboard
    risc
    (Emu.Clipboard.to_clipboard
       (Emu.Clipboard.create
          { Emu.Clipboard.get_text = (fun () -> None); set_text = (fun _ -> ()) }));
  R.set_spi risc 1 (Emu.Disk.to_spi (Emu.Disk.create (Some tmp)));
  Emu.Headless.run_frames risc frames;
  let fb = Array.init fb_words (fun i -> R.framebuffer_word risc i) in
  let hash = Emu.Headless.framebuffer_hash risc in
  (try Sys.remove tmp with
   | Sys_error _ -> ());
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

(* FNV-1a over the framebuffer words, matching Emu.Headless.framebuffer_hash, so the SoC
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

(* Boot our SoC from the disk (the {!Sd_bridge} SD card feeding it) and run PAST the
   handoff until the framebuffer settles (drawn, then unchanged for [settle] chunks) or
   [cap] cycles. Returns (framebuffer words, settled?). *)
let boot_soc ~cap ~chunk ~settle =
  let tmp = copy_to_temp disk_image in
  let bridge = Sd_bridge.create (Emu.Disk.to_spi (Emu.Disk.create (Some tmp))) in
  let sim =
    Sim.create
      ~config:Cyclesim.Config.trace_all
      (Soc.create ~contents:Risc5.Rom.bootloader)
  in
  let inp = Cyclesim.inputs sim
  and outp = Cyclesim.outputs sim in
  let some w = function
    | Some x -> x
    | None -> failwith ("lookup: " ^ w)
  in
  let reg n = some n (Cyclesim.lookup_reg_by_name sim n) in
  let pc = reg "pc"
  and rdy = reg "rdy"
  and shreg = reg "spi_shreg"
  and spi_ctrl = reg "spi_ctrl" in
  let lanes =
    Array.init 4 (fun k ->
      let n = Printf.sprintf "ram%d" k in
      some n (Cyclesim.lookup_mem_by_name sim n))
  in
  let read_fb () =
    Array.init fb_words (fun i ->
      let w = fb_base_word + i in
      let b k = Cyclesim.Memory.to_int lanes.(k) ~address:w in
      (b 3 lsl 24) lor (b 2 lsl 16) lor (b 1 lsl 8) lor b 0)
  in
  let lo = Bits.of_unsigned_int ~width:1 0
  and hi = Bits.of_unsigned_int ~width:1 1 in
  inp.rst_n := lo;
  inp.miso := hi;
  (* idle the peripheral inputs high (released lines); switches/buttons default 0 = disk
     boot, matching the oracle *)
  inp.rxd := hi;
  inp.ps2c := hi;
  inp.ps2d := hi;
  inp.msclk := hi;
  inp.msdat := hi;
  Cyclesim.cycle sim;
  inp.rst_n := hi;
  let cyc = ref 0
  and prev = ref [||]
  and stable = ref 0
  and drawn = ref false in
  while !cyc < cap && !stable < settle do
    for _ = 1 to chunk do
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
      (Cyclesim.Reg.to_int pc)
      (Sd_bridge.nbytes bridge)
      pop
  done;
  (try Sys.remove tmp with
   | Sys_error _ -> ());
  !prev, !stable >= settle
;;

let () =
  (* oracle target: the drawn, stable screen (stable by frame 30; 40 for margin) *)
  let oracle_fb, oracle_hash = boot_oracle 40 in
  Printf.printf
    "oracle (frames=40): hash=0x%Lx  %d set px\n%!"
    oracle_hash
    (popcount oracle_fb);
  Printf.printf
    "booting SoC past the handoff (bit-banged SD — draws ~32-34M cycles in)...\n%!";
  let cap =
    match Sys.getenv_opt "SOC_CAP" with
    | Some s -> int_of_string s
    | None -> 50_000_000
  in
  let soc_fb, settled = boot_soc ~cap ~chunk:2_000_000 ~settle:3 in
  let soc_hash = fb_fnv soc_fb in
  Printf.printf
    "soc: hash=0x%Lx  %d set px  settled=%b\n%!"
    soc_hash
    (popcount soc_fb)
    settled;
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
    "--- ORACLE ---\n%s\n--- SoC ---\n%s\n%!"
    (render oracle_fb ~sx:16 ~sy:16)
    (render soc_fb ~sx:16 ~sy:16);
  if !diffs = 0 && Int64.equal soc_hash oracle_hash
  then
    Printf.printf
      "VISUAL GOLDEN PASS — SoC framebuffer byte-identical to the oracle (hash 0x%Lx)\n"
      oracle_hash
  else (
    Printf.printf
      "VISUAL GOLDEN FAIL: %d/%d framebuffer words differ (first word 0x%X: soc=0x%08X \
       oracle=0x%08X); settled=%b\n"
      !diffs
      fb_words
      (if !first >= 0 then fb_base_word + !first else 0)
      (if !first >= 0 then soc_fb.(!first) else 0)
      (if !first >= 0 then oracle_fb.(!first) else 0)
      settled;
    exit 1)
;;

(* Phase-10a — board visual golden WITH the I-cache: the definitive coherence proof.

   The Phase-6b visual golden (test_visual_golden.ml) renders the idle Oberon desktop on
   the flat-BRAM {!Risc5.Soc} and asserts it is byte-identical to the oracle. This variant
   runs the *board* SoC ({!Nexys4_board.Soc_board} + the {!Nexys4_board.Cellram_model}
   PSRAM double, via the shared {!Board_tb}) with the Phase-10a I-cache ON, past the
   handoff, and asserts the *same* framebuffer against the oracle. That is the strong
   coherence test: if the cache ever served stale code/data — the module loader writing
   code the cache holds, or a framebuffer word the CPU cached being overwritten — the
   desktop would render wrong and the hash would differ. Byte-identical ⇒ the cache is
   transparent through the whole boot + module load + desktop render, not just the
   boot-to-handoff prefix the lockstep bench covers.

   Feasibility note: this is practical *only* with the cache. Cache-off the board runs OS
   code at ~26 cyc/instr, so drawing the desktop would take hundreds of millions of
   cycles; the cache's ~6x (down to ~4.4 cyc/instr) brings it into interpreter range. So
   the cache is what makes a board-level visual golden runnable at all. (AGENT.md §5 Phase
   10.)

   Opt-in: dune build @visual_golden_board. Env: SOC_CAP overrides the cycle cap, ICACHE=0
   runs the (much slower) cache-off control, DISK_IMG the image. *)

module R = Oracle.Risc
open Hardcaml
module Sim = Cyclesim.With_interface (Board_tb.I) (Board_tb.O)

let project_root () =
  let rec up dir =
    if Sys.file_exists (Filename.concat dir "dune-project")
    then dir
    else (
      let parent = Filename.dirname dir in
      if String.equal parent dir
      then failwith "test_visual_golden_board: no dune-project found above cwd"
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
  let tmp = Filename.temp_file "visual_board_" ".dsk" in
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

(* Boot the oracle exactly as test_visual_golden / test_boot.ml does and snapshot the
   drawn, stable framebuffer + its hash. *)
let boot_oracle frames =
  let tmp = copy_to_temp disk_image in
  let risc = R.make () in
  R.set_serial risc (Oracle.Pclink.to_serial (Oracle.Pclink.create ()));
  R.set_clipboard
    risc
    (Oracle.Clipboard.to_clipboard
       (Oracle.Clipboard.create
          { Oracle.Clipboard.get_text = (fun () -> None); set_text = (fun _ -> ()) }));
  R.set_spi risc 1 (Oracle.Disk.to_spi (Oracle.Disk.create (Some tmp)));
  Oracle.Headless.run_frames risc frames;
  let fb = Array.init fb_words (fun i -> R.framebuffer_word risc i) in
  let hash = Oracle.Headless.framebuffer_hash risc in
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

(* FNV-1a over the framebuffer words, matching Oracle.Headless.framebuffer_hash. *)
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

(* Boot the board SoC (SD card via {!Sd_bridge}) with the cache [icache], run PAST the
   handoff until the framebuffer — reconstructed from the PSRAM model's two byte lanes via
   {!Board_tb.read_word} — settles (drawn, then unchanged for [settle] chunks) or [cap]
   cycles. read/write_cycles = 5 to match the board timing the golden is defending. *)
let boot_soc_board ~icache ~write_update ~cap ~chunk ~settle =
  let tmp = copy_to_temp disk_image in
  let bridge = Sd_bridge.create (Oracle.Disk.to_spi (Oracle.Disk.create (Some tmp))) in
  let sim =
    Sim.create ~config:Cyclesim.Config.trace_all (fun i ->
      Board_tb.create ~read_cycles:5 ~write_cycles:5 ~icache ~write_update i)
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
  let cram_lo = some "cram_lo" (Cyclesim.lookup_mem_by_name sim "cram_lo") in
  let cram_hi = some "cram_hi" (Cyclesim.lookup_mem_by_name sim "cram_hi") in
  let read_fb () =
    Array.init fb_words (fun i -> Board_tb.read_word ~cram_lo ~cram_hi (fb_base_word + i))
  in
  let lo = Bits.of_unsigned_int ~width:1 0
  and hi = Bits.of_unsigned_int ~width:1 1 in
  inp.rst_n := lo;
  inp.miso := hi;
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
  let icache =
    match Sys.getenv_opt "ICACHE" with
    | Some "0" -> false
    | _ -> true
  in
  (* opt-in (Phase-10b): WRITE_UPDATE=1 runs the golden with the write-update snoop policy
     — the byte-identical desktop is its coherence proof, like Phase-10a's *)
  let write_update =
    match Sys.getenv_opt "WRITE_UPDATE" with
    | Some "1" -> true
    | _ -> false
  in
  let oracle_fb, oracle_hash = boot_oracle 40 in
  Printf.printf
    "oracle (frames=40): hash=0x%Lx  %d set px\n%!"
    oracle_hash
    (popcount oracle_fb);
  Printf.printf
    "booting BOARD SoC (Cellram PSRAM, icache=%b write_update=%b) past the handoff — \
     cache makes this feasible...\n\
     %!"
    icache
    write_update;
  let cap =
    match Sys.getenv_opt "SOC_CAP" with
    | Some s -> int_of_string s
    | None -> 160_000_000
  in
  let soc_fb, settled =
    boot_soc_board ~icache ~write_update ~cap ~chunk:2_000_000 ~settle:3
  in
  let soc_hash = fb_fnv soc_fb in
  Printf.printf
    "soc (icache=%b): hash=0x%Lx  %d set px  settled=%b\n%!"
    icache
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
    "--- ORACLE ---\n%s\n--- SoC (board, icache=%b) ---\n%s\n%!"
    (render oracle_fb ~sx:16 ~sy:16)
    icache
    (render soc_fb ~sx:16 ~sy:16);
  if !diffs = 0 && Int64.equal soc_hash oracle_hash
  then
    Printf.printf
      "VISUAL GOLDEN (BOARD, icache=%b) PASS — board-SoC framebuffer byte-identical to \
       the oracle (hash 0x%Lx). The I-cache is transparent through boot + module load + \
       desktop render.\n"
      icache
      oracle_hash
  else (
    Printf.printf
      "VISUAL GOLDEN (BOARD, icache=%b) FAIL: %d/%d framebuffer words differ (first word \
       0x%X: soc=0x%08X oracle=0x%08X); settled=%b\n"
      icache
      !diffs
      fb_words
      (if !first >= 0 then fb_base_word + !first else 0)
      (if !first >= 0 then soc_fb.(!first) else 0)
      (if !first >= 0 then oracle_fb.(!first) else 0)
      settled;
    exit 1)
;;

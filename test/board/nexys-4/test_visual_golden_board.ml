(* Phase-10a — board visual golden WITH the I-cache: the definitive coherence proof.

   The Phase-6b visual golden (test_visual_golden.ml) renders the idle Oberon desktop on
   the flat-BRAM {!Risc5.Soc} and asserts it is byte-identical to the oracle. This variant
   runs the *board* SoC ({!Nexys4_board.Soc} + the {!Nexys4_board.Cellram_model} PSRAM
   double, via the shared {!Board_tb}) with the Phase-10a I-cache ON, past the handoff,
   and asserts the *same* framebuffer against the oracle. That is the strong coherence
   test: if the cache ever served stale code/data — the module loader writing code the
   cache holds, or a framebuffer word the CPU cached being overwritten — the desktop would
   render wrong and the hash would differ. Byte-identical ⇒ the cache is transparent
   through the whole boot + module load + desktop render, not just the boot-to-handoff
   prefix the lockstep bench covers.

   Feasibility note: this is practical *only* with the cache. Cache-off the board runs OS
   code at ~26 cyc/instr, so drawing the desktop would take hundreds of millions of
   cycles; the cache's ~6x (down to ~4.4 cyc/instr) brings it into interpreter range. So
   the cache is what makes a board-level visual golden runnable at all. (AGENT.md §5 Phase
   10.)

   The fb geometry, oracle boot, settle loop and verdict are shared in
   {!Boot_checkpoint_common}; the SPI drive in {!Boot_tb}. This file keeps what is
   board-specific: the knobs, the board wait counts, and the FB_BRAM shadow readback + its
   coherence check.

   Opt-in: dune build @visual_golden_board. By default it boots exactly the configuration
   the bitstream ships ({!Nexys4_board.Build_config.shipped}: 16 KiB cache, write-update,
   framebuffer shadow, Halftone instantiated, depth-2 write buffer, pipelined DSP
   multiplies, the board's PSRAM wait counts). The environment overrides of
   {!Board_tb.config_of_env} are controls for bisecting or A/B runs (e.g. ICACHE=0 — much
   slower — FB_BRAM=0 HALFTONE=0, WBUF=0, FAST_MUL=0, LINES_LOG2=10); SOC_CAP overrides
   the cycle cap, DISK_IMG the image. Under [fb_bram] the golden reads the *shadow* — the
   words the screen actually shows — and additionally asserts shadow ≡ PSRAM framebuffer
   window over the full span, the shadow's own coherence invariant. After the framebuffer
   verdict one more raster frame is scanned off the rgb pins and must reproduce it. *)

open Hardcaml
module BCC = Boot_checkpoint_common
module Sim = Cyclesim.With_interface (Board_tb.I) (Board_tb.O)

(* Boot the board SoC (SD card via {!Sd_bridge}) in configuration [cfg], run PAST the
   handoff until the framebuffer — reconstructed from the PSRAM model's two byte lanes via
   {!Board_tb.read_word}, or from the {!Nexys4_board.Framebuf} shadow under [fb_bram] —
   settles or [cap] cycles; then scan one frame off the rgb pins. *)
let boot_board ~(cfg : Nexys4_board.Build_config.t) ~target ~cap ~chunk ~settle =
  let tmp = BCC.copy_to_temp BCC.disk_image in
  let bridge = Sd_bridge.create (Emu.Disk.to_spi (Emu.Disk.create (Some tmp))) in
  let sim =
    Sim.create
      ~config:Cyclesim.Config.trace_all
      (Board_tb.create ~datasheet_chip:true cfg)
  in
  let inp = Cyclesim.inputs sim
  and outp = Cyclesim.outputs sim in
  let spi = Boot_tb.Spi.attach sim ~miso:inp.miso ~sclk:outp.sclk bridge in
  let pc = Boot_tb.lookup_reg sim "pc" in
  let cram_lo = Boot_tb.lookup_mem sim "cram_lo"
  and cram_hi = Boot_tb.lookup_mem sim "cram_hi" in
  (* under FB_BRAM the golden reads the *shadow* — the words the raster actually fetches;
     the PSRAM window stays readable for the shadow-equality check below *)
  let fb_lanes =
    if cfg.fb_bram
    then Some (Array.init 4 (fun k -> Boot_tb.lookup_mem sim (Printf.sprintf "fb%d" k)))
    else None
  in
  let shadow_word lanes idx =
    let b k = Cyclesim.Memory.to_int lanes.(k) ~address:idx in
    b 0 lor (b 1 lsl 8) lor (b 2 lsl 16) lor (b 3 lsl 24)
  in
  let read_fb () =
    match fb_lanes with
    | Some lanes ->
      Array.init BCC.fb_words (fun i ->
        shadow_word lanes (BCC.fb_base_word - Nexys4_board.Framebuf.base + i))
    | None ->
      Array.init BCC.fb_words (fun i ->
        Board_tb.read_word ~cram_lo ~cram_hi (BCC.fb_base_word + i))
  in
  let lo = Bits.of_unsigned_int ~width:1 0
  and hi = Bits.of_unsigned_int ~width:1 1 in
  Board_tb.drive_idle inp;
  inp.rst_n := lo;
  Cyclesim.cycle sim;
  inp.rst_n := hi;
  let tick () = Boot_tb.Spi.tick sim spi in
  let fb, settled =
    BCC.run_to_settle
      ~target
      ~cap
      ~chunk
      ~settle
      ~tick
      ~read_fb
      ~pc:(fun () -> Cyclesim.Reg.to_int pc)
      ~spi_bytes:(fun () -> Sd_bridge.nbytes bridge)
      ()
  in
  (* the shadow's own invariant, checked over the FULL span at the settled (quiet) point:
     every shadow word equals its PSRAM word — both zero-initialised, and every in-window
     store wrote both, so any mismatch is a shadow write-path bug *)
  let shadow_mismatches =
    match fb_lanes with
    | None -> None
    | Some lanes ->
      let m = ref 0 in
      for idx = 0 to Nexys4_board.Framebuf.size - 1 do
        if shadow_word lanes idx
           <> Board_tb.read_word ~cram_lo ~cram_hi (Nexys4_board.Framebuf.base + idx)
        then incr m
      done;
      Some !m
  in
  (* one more frame, watching the pins: what scans out must be what the memory holds *)
  let scan, stray = Boot_tb.scan_frame sim ~tick ~rgb:outp.rgb in
  BCC.rm_temp tmp;
  fb, settled, shadow_mismatches, scan, stray
;;

let () =
  let cfg = Board_tb.config_of_env () in
  let shipped = cfg = Nexys4_board.Build_config.shipped in
  let oracle_fb, oracle_hash = BCC.boot_oracle_fb ~frames:40 in
  Printf.printf
    "oracle (frames=40): hash=0x%Lx  %d set px\n%!"
    oracle_hash
    (BCC.popcount oracle_fb);
  Printf.printf
    "booting the BOARD SoC past the handoff — %s configuration:\n  %s\n%!"
    (if shipped then "the SHIPPED" else "a NON-SHIPPED (overridden)")
    (Nexys4_board.Build_config.to_string cfg);
  let cap =
    match Sys.getenv_opt "SOC_CAP" with
    | Some s -> int_of_string s
    | None -> 160_000_000
  in
  let soc_fb, settled, shadow_mismatches, scan, stray =
    boot_board ~cfg ~target:oracle_hash ~cap ~chunk:2_000_000 ~settle:3
  in
  (match shadow_mismatches with
   | None -> ()
   | Some 0 ->
     Printf.printf
       "shadow check: all %d shadow words = PSRAM framebuffer window (coherent)\n%!"
       Nexys4_board.Framebuf.size
   | Some m ->
     Printf.printf
       "shadow check FAIL: %d/%d shadow words differ from the PSRAM window\n%!"
       m
       Nexys4_board.Framebuf.size;
     exit 1);
  let soc_hash = BCC.fb_fnv soc_fb in
  Printf.printf
    "soc: hash=0x%Lx  %d set px  settled=%b\n%!"
    soc_hash
    (BCC.popcount soc_fb)
    settled;
  let tag =
    if shipped then " (BOARD, shipped config)" else " (BOARD, overridden config)"
  in
  BCC.golden_report
    ~tag
    ~subject:"board-SoC"
    ~render_label:"SoC (board)"
    ~pass_tail:
      ". The memory stack is transparent through boot + module load + desktop render."
    ~oracle_fb
    ~oracle_hash
    ~soc_fb
    ~soc_hash
    ~settled;
  BCC.scanout_report ~soc_fb ~scan ~stray
;;

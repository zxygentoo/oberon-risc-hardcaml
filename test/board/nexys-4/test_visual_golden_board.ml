(* The visual golden through the board SoC: the idle desktop must be byte-identical to the
   oracle's with the whole memory stack in the way. If the cache ever served stale code or
   data — the module loader writing code the cache holds, say — the desktop would come out
   wrong.

   By default it boots exactly what the bitstream ships
   ({!Nexys4_board.Build_config.shipped}); the environment overrides of
   {!Board_tb.config_of_env} are controls for bisecting (ICACHE=0 is very slow: without
   the cache the OS runs at some 28 clocks per instruction). SOC_CAP overrides the cycle
   cap, DISK_IMG the image.

   With the framebuffer shadow the golden reads the shadow, the words the screen actually
   shows, and also requires the shadow to equal the PSRAM's framebuffer window over the
   whole span. After the framebuffer verdict one more frame is scanned off the rgb pins
   and must reproduce it. *)

open Hardcaml
module Sim = Cyclesim.With_interface (Board_tb.I) (Board_tb.O)

(* Boot the board SoC (SD card via {!Boot.Sd_bridge}) in configuration [cfg], run PAST the
   handoff until the framebuffer — reconstructed from the PSRAM model's two byte lanes via
   {!Board_tb.read_word}, or from the {!Nexys4_board.Framebuf} shadow under [fb_bram] —
   settles or [cap] cycles; then scan one frame off the rgb pins. *)
let boot_board ~(cfg : Nexys4_board.Build_config.t) ~target ~cap ~chunk ~settle =
  let tmp = Boot.Disk.copy_to_temp Boot.Disk.image in
  let bridge = Boot.Sd_bridge.create (Emu.Disk.to_spi (Emu.Disk.create (Some tmp))) in
  let sim =
    Sim.create
      ~config:Cyclesim.Config.trace_all
      (Board_tb.create ~datasheet_chip:true cfg)
  in
  let inp = Cyclesim.inputs sim
  and outp = Cyclesim.outputs sim in
  let spi = Boot.Tb.Spi.attach sim ~miso:inp.miso ~sclk:outp.sclk bridge in
  let pc = Boot.Tb.lookup_reg sim "pc" in
  let cram_lo = Boot.Tb.lookup_mem sim "cram_lo"
  and cram_hi = Boot.Tb.lookup_mem sim "cram_hi" in
  (* under FB_BRAM the golden reads the *shadow* — the words the raster actually fetches;
     the PSRAM window stays readable for the shadow-equality check below *)
  let fb_lanes =
    if cfg.fb_bram
    then Some (Array.init 4 (fun k -> Boot.Tb.lookup_mem sim (Printf.sprintf "fb%d" k)))
    else None
  in
  let shadow_word lanes idx =
    let b k = Cyclesim.Memory.to_int lanes.(k) ~address:idx in
    b 0 lor (b 1 lsl 8) lor (b 2 lsl 16) lor (b 3 lsl 24)
  in
  let read_fb () =
    match fb_lanes with
    | Some lanes ->
      Array.init Boot.Golden.fb_words (fun i ->
        shadow_word lanes (Boot.Golden.fb_base_word - Nexys4_board.Framebuf.base + i))
    | None ->
      Array.init Boot.Golden.fb_words (fun i ->
        Board_tb.read_word ~cram_lo ~cram_hi (Boot.Golden.fb_base_word + i))
  in
  let lo = Bits.of_unsigned_int ~width:1 0
  and hi = Bits.of_unsigned_int ~width:1 1 in
  Board_tb.drive_idle inp;
  inp.rst_n := lo;
  Cyclesim.cycle sim;
  inp.rst_n := hi;
  let tick () = Boot.Tb.Spi.tick sim spi in
  let fb, settled =
    Boot.Golden.run_to_settle
      ~target
      ~cap
      ~chunk
      ~settle
      ~tick
      ~read_fb
      ~pc:(fun () -> Cyclesim.Reg.to_int pc)
      ~spi_bytes:(fun () -> Boot.Sd_bridge.nbytes bridge)
      ()
  in
  (* the shadow's own invariant, over the whole span, once the machine has settled: every
     shadow word equals its PSRAM word (in simulation both start as zero, and every store
     in the window writes both) *)
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
  let scan, stray = Boot.Tb.scan_frame sim ~tick ~rgb:outp.rgb in
  Boot.Disk.rm_temp tmp;
  fb, settled, shadow_mismatches, scan, stray
;;

let () =
  let cfg = Board_tb.config_of_env () in
  let shipped = cfg = Nexys4_board.Build_config.shipped in
  let oracle_fb, oracle_hash = Boot.Golden.boot_oracle_fb ~frames:40 in
  Printf.printf
    "oracle (frames=40): hash=0x%Lx  %d set px\n%!"
    oracle_hash
    (Boot.Golden.popcount oracle_fb);
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
  let soc_hash = Boot.Golden.fb_fnv soc_fb in
  Printf.printf
    "soc: hash=0x%Lx  %d set px  settled=%b\n%!"
    soc_hash
    (Boot.Golden.popcount soc_fb)
    settled;
  Boot.Golden.report
    ~machine:
      (if shipped
       then "the board SoC, shipped configuration"
       else "the board SoC, OVERRIDDEN configuration")
    ~oracle_fb
    ~oracle_hash
    ~soc_fb
    ~soc_hash
    ~settled;
  Boot.Golden.scanout_report ~soc_fb ~scan ~stray
;;

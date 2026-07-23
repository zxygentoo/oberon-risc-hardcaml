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
   chunks (the loop is {!Boot_checkpoint_common.run_to_settle}; the fb geometry, oracle
   boot, render and verdict are shared there too).

   Opt-in (boots the real disk): [dune build @visual_golden]; [SOC_CAP] overrides the cap,
   [DISK_IMG] the image. *)

open Hardcaml
module BCC = Boot_checkpoint_common
module Soc = Risc5.Soc
module Sim = Cyclesim.With_interface (Soc.I) (Soc.O)

(* Boot our SoC from the disk (the {!Sd_bridge} SD card feeding it) and run PAST the
   handoff until the framebuffer settles — or matches the oracle hash [target], the early
   exit — or [cap] cycles. Returns (fb words, settled?). *)
let boot_soc ~target ~cap ~chunk ~settle =
  let tmp = BCC.copy_to_temp BCC.disk_image in
  let bridge = Sd_bridge.create (Emu.Disk.to_spi (Emu.Disk.create (Some tmp))) in
  let spi_slow_div_log2 = Option.map int_of_string (Sys.getenv_opt "SPI_DIV_LOG2") in
  let sim =
    Sim.create
      ~config:Cyclesim.Config.trace_all
      (Soc.create ~contents:Risc5.Rom.bootloader ?spi_slow_div_log2)
  in
  let inp = Cyclesim.inputs sim
  and outp = Cyclesim.outputs sim in
  let spi = Boot_tb.Spi.attach sim ~miso:inp.miso ~sclk:outp.sclk bridge in
  let pc = Boot_tb.lookup_reg sim "pc" in
  let lanes = Array.init 4 (fun k -> Boot_tb.lookup_mem sim (Printf.sprintf "ram%d" k)) in
  let read_fb () =
    Array.init BCC.fb_words (fun i ->
      let w = BCC.fb_base_word + i in
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
  let fb, settled =
    BCC.run_to_settle
      ~target
      ~cap
      ~chunk
      ~settle
      ~tick:(fun () -> Boot_tb.Spi.tick sim spi)
      ~read_fb
      ~pc:(fun () -> Cyclesim.Reg.to_int pc)
      ~spi_bytes:(fun () -> Sd_bridge.nbytes bridge)
      ()
  in
  BCC.rm_temp tmp;
  fb, settled
;;

let () =
  (* oracle target: the drawn, stable screen (stable by frame 30; 40 for margin) *)
  let oracle_fb, oracle_hash = BCC.boot_oracle_fb ~frames:40 in
  Printf.printf
    "oracle (frames=40): hash=0x%Lx  %d set px\n%!"
    oracle_hash
    (BCC.popcount oracle_fb);
  Printf.printf
    "booting SoC past the handoff (bit-banged SD — draws ~32-34M cycles in)...\n%!";
  let cap =
    match Sys.getenv_opt "SOC_CAP" with
    | Some s -> int_of_string s
    | None -> 50_000_000
  in
  let soc_fb, settled = boot_soc ~target:oracle_hash ~cap ~chunk:2_000_000 ~settle:3 in
  let soc_hash = BCC.fb_fnv soc_fb in
  Printf.printf
    "soc: hash=0x%Lx  %d set px  settled=%b\n%!"
    soc_hash
    (BCC.popcount soc_fb)
    settled;
  BCC.golden_report
    ~tag:""
    ~subject:"SoC"
    ~render_label:"SoC"
    ~pass_tail:""
    ~oracle_fb
    ~oracle_hash
    ~soc_fb
    ~soc_hash
    ~settled
;;

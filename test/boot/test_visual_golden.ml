(* The visual golden on the simulation SoC.

   The boot continues past the handoff to the idle desktop, and the framebuffer must equal
   the oracle's bit for bit (hash 0xb9bdbf56ba51298d, 18607 pixels set). The oracle's boot
   is deterministic and its idle screen static. The SoC takes far longer to get there: it
   talks to the SD card over SPI at real timing, where the oracle's disk answers at once,
   so the desktop is complete only after some 33 M cycles. One more frame is then scanned
   off the rgb pins and must reproduce the framebuffer.

   [SOC_CAP] overrides the cycle cap, [DISK_IMG] the image. *)

open Hardcaml
module Soc = Risc5.Soc
module Sim = Cyclesim.With_interface (Soc.I) (Soc.O)

(* Boot our SoC from the disk (the {!Boot.Sd_bridge} SD card feeding it) and run PAST the
   handoff until the framebuffer settles — or matches the oracle hash [target], the early
   exit — or [cap] cycles. Returns (fb words, settled?). *)
let boot_soc ~target ~cap ~chunk ~settle =
  let tmp = Boot.Disk.copy_to_temp Boot.Disk.image in
  let bridge = Boot.Sd_bridge.create (Emu.Disk.to_spi (Emu.Disk.create (Some tmp))) in
  let spi_slow_div_log2 = Option.map int_of_string (Sys.getenv_opt "SPI_DIV_LOG2") in
  let sim =
    Sim.create
      ~config:Cyclesim.Config.trace_all
      (Soc.create ~contents:Risc5.Rom.bootloader ?spi_slow_div_log2)
  in
  let inp = Cyclesim.inputs sim
  and outp = Cyclesim.outputs sim in
  let spi = Boot.Tb.Spi.attach sim ~miso:inp.miso ~sclk:outp.sclk bridge in
  let pc = Boot.Tb.lookup_reg sim "pc" in
  let lanes = Array.init 4 (fun k -> Boot.Tb.lookup_mem sim (Printf.sprintf "ram%d" k)) in
  let read_fb () =
    Array.init Boot.Golden.fb_words (fun i ->
      let w = Boot.Golden.fb_base_word + i in
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
    Boot.Golden.run_to_settle
      ~target
      ~cap
      ~chunk
      ~settle
      ~tick:(fun () -> Boot.Tb.Spi.tick sim spi)
      ~read_fb
      ~pc:(fun () -> Cyclesim.Reg.to_int pc)
      ~spi_bytes:(fun () -> Boot.Sd_bridge.nbytes bridge)
      ()
  in
  (* one more frame, watching the pins: what scans out must be what the memory holds *)
  let scan, stray =
    Boot.Tb.scan_frame sim ~tick:(fun () -> Boot.Tb.Spi.tick sim spi) ~rgb:outp.rgb
  in
  Boot.Disk.rm_temp tmp;
  fb, settled, scan, stray
;;

let () =
  (* oracle target: the drawn, stable screen (stable by frame 30; 40 for margin) *)
  let oracle_fb, oracle_hash = Boot.Golden.boot_oracle_fb ~frames:40 in
  Printf.printf
    "oracle (frames=40): hash=0x%Lx  %d set px\n%!"
    oracle_hash
    (Boot.Golden.popcount oracle_fb);
  Printf.printf
    "booting SoC past the handoff (bit-banged SD — draws ~32-34M cycles in)...\n%!";
  let cap =
    match Sys.getenv_opt "SOC_CAP" with
    | Some s -> int_of_string s
    | None -> 50_000_000
  in
  let soc_fb, settled, scan, stray =
    boot_soc ~target:oracle_hash ~cap ~chunk:2_000_000 ~settle:3
  in
  let soc_hash = Boot.Golden.fb_fnv soc_fb in
  Printf.printf
    "soc: hash=0x%Lx  %d set px  settled=%b\n%!"
    soc_hash
    (Boot.Golden.popcount soc_fb)
    settled;
  Boot.Golden.report
    ~machine:"the sim SoC"
    ~oracle_fb
    ~oracle_hash
    ~soc_fb
    ~soc_hash
    ~settled;
  Boot.Golden.scanout_report ~soc_fb ~scan ~stray
;;

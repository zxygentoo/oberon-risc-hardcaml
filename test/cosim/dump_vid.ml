(* RTL-fidelity dumper for the video controller. Unlike the serial units, VID is two-clock
   and largely autonomous (the raster free-runs), so the dumper runs the Hardcaml port
   under By_input_clocks at the real 65:25 ratio (pclk period 5, clk period 13 — each
   Cyclesim.cycle is one fine base tick) and records, per base tick, the inputs it drove
   (inv, viddata) plus every output. The Verilator harness (test/cosim/vid.cpp) replays
   the identical per-tick inputs through vid_cosim.v (the real VID60.v with clk/pclk
   driven at the same 13:5 cadence) and asserts, every tick, RTL (req, vidadr, hsync,
   vsync, RGB) == the port's.

   Coverage: ~2 full scanlines (2688 pclks) — visible pixels, the 32-word/line DMA, vidadr
   across a line, hblank (hcnt>=1024) and the hsync pulse, the hcnt wrap + vcnt advance,
   and an inv toggle. vblank/vsync (vcnt>=768) need a whole frame (~768 lines) to reach
   and are the same comparator-free / SR-latch idiom as hblank/hsync, so they're left to a
   full-frame run (the Phase-6 visual golden); here they're exercised in their inactive
   state.

   Line format (one per base tick): "inv viddata req vidadr hsync vsync rgb". *)

open Hardcaml
module Vid = Risc5.Vid
module Sim = Cyclesim.With_interface (Vid.I) (Vid.O)

let () =
  let config =
    { Cyclesim.Config.trace_all with
      clock_mode =
        Cyclesim.Config.Clock_mode.By_input_clocks
          (Cyclesim_clock_domain.create_list [ "clk", 13; "pclk", 5 ])
    }
  in
  let sim = Sim.create ~config Vid.create in
  let inp = (Cyclesim.inputs sim : _ Vid.I.t) in
  let outp = (Cyclesim.outputs sim : _ Vid.O.t) in
  let set r v = r := Bits.of_unsigned_int ~width:(Bits.width !r) v in
  let rd r = Bits.to_int_trunc !r in
  let ticks = 13440 in
  (* deterministic pseudo-random viddata per tick (a plain LCG); recorded in the dump, so
     the .cpp replays the exact sequence — varying it every tick stresses the vidbuf
     latch + shift *)
  let seed = ref 0x1234_5678 in
  let next_word () =
    seed := ((!seed * 1103515245) + 12345) land 0xFFFFFFFF;
    !seed
  in
  for t = 0 to ticks - 1 do
    let inv = if t >= 5000 && t < 9000 then 1 else 0 in
    let vd = next_word () in
    set inp.inv inv;
    set inp.viddata vd;
    Cyclesim.cycle sim;
    Printf.printf
      "%d %08x %d %05x %d %d %02x\n"
      inv
      vd
      (rd outp.req)
      (rd outp.vidadr)
      (rd outp.hsync)
      (rd outp.vsync)
      (rd outp.rgb)
  done;
  Printf.eprintf "dump_vid: %d ticks (~2 scanlines)\n" ticks
;;

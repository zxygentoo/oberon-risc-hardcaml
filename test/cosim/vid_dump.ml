(* RTL-fidelity dumper for the video controller. Unlike the serial units, VID is two-clock
   and largely autonomous (the raster free-runs), so the dumper runs the Hardcaml port
   under By_input_clocks at the real 65:25 ratio (pclk period 5, clk period 13 — each
   Cyclesim.cycle is one fine base tick) and records, per base tick, the inputs it drove
   (inv, viddata) plus every output. The Verilator harness (test/cosim/vid.cpp) drives the
   identical [inv] into vid_cosim.v (the real VID60.v with clk/pclk at the same 13:5
   cadence) and asserts, every tick, RTL (hsync, vsync, RGB) == the port's; [req] is
   checked by pulse COUNT, and [vidadr] is NOT compared (both are deliberate departures —
   see below).

   Identity-echo framebuffer. [viddata] is driven = the requested [vidadr] (mem[a] = a),
   and the harness drives VID60.v's [viddata] from VID60.v's OWN [vidadr] the same way.
   Two reasons this echo (not the old per-tick / per-group word):
   - [vidadr] is stable across each 32-px group, so the value sampled is the same
     regardless of WHEN within the group each side samples — which absorbs BOTH the
     req-CDC sampling jitter (our toggle synchroniser fires req ~2 clk later than
     VID60.v's async-set req1) AND lets the pixel path stay comparable despite the
     prefetch's look-ahead address.
   - The 2-group PREFETCH makes our [vidadr] lead VID60.v's by one group every tick, so a
     single replayed [viddata] stream can't be correct for both sides at once. Echoing
     each side's OWN address gives both the identical identity framebuffer — so they
     render the same pixels (col's word in group col+1) even though each fetched on its
     own schedule.

   Coverage: ~3 scanlines (4032 pclks) — visible pixels, the 32-word/line DMA, vidadr
   across a line, hblank (hcnt>=1024) + the hsync pulse, the hcnt wrap + vcnt advance, and
   an inv toggle. The harness skips RGB over the first scanline (the prefetch frame-top
   gap — see vid.cpp). vblank/vsync (vcnt>=768) need a whole frame (~768 lines) to reach
   and are the same comparator-free / SR-latch idiom as hblank/hsync, so they're left to a
   full-frame run (the Phase-6 visual golden); here they're exercised in their inactive
   state.

   Line format (one per base tick): "inv viddata req vidadr hsync vsync rgb". *)

open Hardcaml
open Cosim_dump
module Video = Risc5.Video
module Sim = Cyclesim.With_interface (Video.I) (Video.O)

let () =
  let config =
    { Cyclesim.Config.trace_all with
      clock_mode =
        Cyclesim.Config.Clock_mode.By_input_clocks
          (Cyclesim_clock_domain.create_list [ "clk", 13; "pclk", 5 ])
    }
  in
  let sim = Sim.create ~config Video.create in
  let inp = (Cyclesim.inputs sim : _ Video.I.t) in
  let outp = (Cyclesim.outputs sim : _ Video.O.t) in
  let ticks = 3 * 1344 * 5 in
  for t = 0 to ticks - 1 do
    let inv = if t >= 8000 && t < 14000 then 1 else 0 in
    (* identity-echo framebuffer: drive viddata = the word at the requested address
       (mem[a] = a). Read the CURRENT vidadr (combinational from the raster counters,
       stable across the 32-px group) and feed it back, then step — exactly the pattern
       the co-located prefetch look-ahead test uses, and what the harness mirrors on
       VID60.v. *)
    let vd = rd outp.vidadr in
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
  done
;;

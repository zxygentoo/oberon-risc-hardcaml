(* The dumper for the video controller. Video has two clocks and runs by itself, so the
   port is simulated under By_input_clocks at the real 65:25 ratio (pclk period 5, clk
   period 13, one Cyclesim.cycle per base tick), and every base tick the inputs driven and
   all outputs are recorded. vid.cpp drives the same [inv] into vid_cosim.v, which is
   VID60.v with its two clocks at the same cadence, and requires the same hsync, vsync and
   RGB every tick. [req] is compared by its number of pulses and [vidadr] not at all:
   those are the port's two deliberate departures.

   The framebuffer is an echo: each side's [viddata] is driven with its own [vidadr]. The
   port requests a group's word one group earlier than VID60.v does, so no single replayed
   stream of data could be right for both; with the echo both sides display the same
   picture, each column showing its own address. And because [vidadr] is steady across a
   group, it does not matter that the two sides sample it at slightly different moments.

   About three scan lines are covered: visible pixels, the 32 fetches of a line,
   horizontal blanking and sync, the wrap of hcnt and the step of vcnt, and a toggle of
   [inv]. RGB is not compared over the first line, whose first group the port has not yet
   fetched. Vertical blanking and sync would need a whole frame; the visual goldens cover
   them.

   Line, one per base tick: "inv viddata req vidadr hsync vsync rgb". *)

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
    (* the echo: drive [viddata] with the address requested, which is steady across the
       group *)
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

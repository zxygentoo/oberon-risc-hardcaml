(* RTL-fidelity dumper for the RS232 transmitter. Like dump_spi (a serial peripheral with
   a start/rdy handshake, not stall-based) but OUTPUT-ONLY: RS232T has no per-cycle input
   to record (no MISO), so the per-cycle trace carries just the two outputs to check.

   For each frame it drives Risc5.Rs232t over (fsel, data) and records, for EVERY cycle
   from [start] to [rdy] re-raising, the (rdy, txd) it observed; the matching Verilator
   harness (test/cosim/rs232t.cpp) replays the identical (fsel, data) through
   test/_po/verilog/src/RS232T.v and asserts, cycle-by-cycle, RTL (rdy, TxD) == port's,
   plus frame length == port's. There is no value column: [txd] IS the serialised value,
   checked every cycle.

   Line format: "fsel data cycles hextrace" where hextrace is one hex digit per cycle:
   bit1 = rdy, bit0 = txd (the port outputs). *)

open Hardcaml
open Cosim_dump
module Rs232t = Risc5.Rs232t
module Sim = Cyclesim.With_interface (Rs232t.I) (Rs232t.O)

let cap = 14000 (* safety: the slow frame is ~13030 cycles (10 bits x clk/1302) *)

let () =
  let sim = Sim.create Rs232t.create in
  let inp = (Cyclesim.inputs sim : _ Rs232t.I.t) in
  let outp = (Cyclesim.outputs sim : _ Rs232t.O.t) in
  (* reset (rst_n active-low, synchronous), then run frames back-to-back: after each one
     the unit returns to rdy=1 / tick=0, so [start] re-arms it cleanly — no per-frame
     reset, exactly as the .cpp does. *)
  set inp.rst_n 0;
  set inp.start 0;
  set inp.fsel 0;
  set inp.data 0;
  Cyclesim.cycle sim;
  set inp.rst_n 1;
  Cyclesim.cycle sim;
  (* one frame: drive [start] for edge 0, then cycle until [rdy] re-raises, recording
     per-cycle (rdy, txd). Returns (cycles, hextrace); [cycles] = trace length = edges
     from start to rdy re-raise. *)
  let frame ~fsel ~data =
    let buf = Buffer.create 256 in
    let push () =
      let nib = (rd outp.rdy lsl 1) lor rd outp.txd in
      Buffer.add_char buf (hex_digit nib)
    in
    set inp.fsel fsel;
    set inp.data data;
    set inp.start 1;
    Cyclesim.cycle sim;
    (* edge 0: start sampled (run<=1, shreg<={data,0}) *)
    push ();
    set inp.start 0;
    let n = ref 1 in
    let going = ref true in
    while !going && !n < cap do
      Cyclesim.cycle sim;
      push ();
      incr n;
      if rd outp.rdy = 1 then going := false
    done;
    !n, Buffer.contents buf
  in
  let count = ref 0 in
  let emit ~fsel ~data =
    let cycles, trace = frame ~fsel ~data in
    Printf.printf "%d %02X %d %s\n" fsel data cycles trace;
    incr count
  in
  (* corner bytes in both rates, then a fuzz pass biased to the cheap fast rate (fsel=1,
     ~2180 cy) over the slow rate (fsel=0, ~13030 cy). The framing is data-independent in
     structure (only WHICH bits appear on txd changes), so a modest spread of bit patterns
     across both rates exhausts the datapath. *)
  let corners = [ 0x00; 0xFF; 0xA5; 0x5A; 0x01; 0x80; 0x7F; 0xC3 ] in
  List.iter
    (fun d ->
      emit ~fsel:1 ~data:d;
      emit ~fsel:0 ~data:d)
    corners;
  let rng = Random.State.make [| 0x232 |] in
  for _ = 1 to 64 do
    emit ~fsel:1 ~data:(Random.State.int rng 256)
  done;
  for _ = 1 to 8 do
    emit ~fsel:0 ~data:(Random.State.int rng 256)
  done;
  Printf.eprintf "dump_rs232t: %d frames (corners x2 + 64 fast + 8 slow fuzz)\n" !count
;;

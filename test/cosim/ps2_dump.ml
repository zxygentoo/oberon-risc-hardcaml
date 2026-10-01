(* The dumper for the PS/2 keyboard receiver. It plays the keyboard: it clocks a frame in
   on (ps2c, ps2d), pops the byte with [done_], and records every cycle the inputs it
   drove and the [rdy] it saw. ps2.cpp replays the same waveform through PS2.v and
   requires the same [rdy] every cycle, and the same data whenever [rdy] is high.

   The FIFO pointers advance, and wrap, across these one-byte frames; the order of several
   queued bytes is checked by the unit's own test.

   Line: "data hextrace", one digit per cycle: bit 3 = done_, bit 2 = ps2c, bit 1 = ps2d,
   bit 0 = rdy. *)

open Hardcaml
open Cosim_dump
module Ps2 = Risc5.Ps2
module Sim = Cyclesim.With_interface (Ps2.I) (Ps2.O)

let h = 4 (* ps2c half-period in clocks (>=2 for the synchronizer to see the edge) *)

let () =
  let sim = Sim.create Ps2.create in
  let inp = (Cyclesim.inputs sim : _ Ps2.I.t) in
  let outp = (Cyclesim.outputs sim : _ Ps2.O.t) in
  (* reset (rst_n active-low, synchronous), ps2c/ps2d idle high; then frames back-to-back,
     each ending with a [done_] pop, exactly as the .cpp does. *)
  set inp.rst_n 0;
  set inp.ps2c 1;
  set inp.ps2d 1;
  set inp.done_ 0;
  Cyclesim.cycle sim;
  set inp.rst_n 1;
  Cyclesim.cycle sim;
  (* one frame: clock 11 bits (start, 8 data LSbit-first, parity, stop) on ps2c/ps2d, let
     [endbit] push the byte, then pop with [done_]. Records per cycle (done_<<3 | ps2c<<2
     | ps2d<<1 | rdy). Returns (recovered_byte, hextrace). *)
  let frame ~data =
    let buf = Buffer.create 256 in
    let push () =
      let nib =
        (rd inp.done_ lsl 3)
        lor (rd inp.ps2c lsl 2)
        lor (rd inp.ps2d lsl 1)
        lor rd outp.rdy
      in
      Buffer.add_char buf (hex_digit nib)
    in
    let send_bit b =
      set inp.ps2d b;
      set inp.ps2c 1;
      for _ = 1 to h do
        Cyclesim.cycle sim;
        push ()
      done;
      set inp.ps2c 0;
      for _ = 1 to h do
        Cyclesim.cycle sim;
        push ()
      done
    in
    List.iter (fun b -> send_bit (Bool.to_int b)) (Ps2.For_tests.frame_bits data);
    set inp.ps2c 1;
    for _ = 1 to h do
      Cyclesim.cycle sim;
      push ()
    done;
    let recv = rd outp.data in
    set inp.done_ 1;
    Cyclesim.cycle sim;
    push ();
    set inp.done_ 0;
    for _ = 1 to 2 do
      Cyclesim.cycle sim;
      push ()
    done;
    recv, Buffer.contents buf
  in
  let emit ~data =
    let recv, trace = frame ~data in
    Printf.printf "%02X %s\n" recv trace
  in
  let corners = [ 0x00; 0xFF; 0xA5; 0x5A; 0x01; 0x80; 0x7F; 0x1C ] in
  List.iter (fun d -> emit ~data:d) corners;
  let rng = Random.State.make [| 0x732 |] in
  for _ = 1 to 40 do
    emit ~data:(Random.State.int rng 256)
  done
;;

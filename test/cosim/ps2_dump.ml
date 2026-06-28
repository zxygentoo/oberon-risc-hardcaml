(* RTL-fidelity dumper for the PS/2 keyboard receiver. Input-driven like rs232r_dump: the
   dumper plays the keyboard, clocking an 11-bit frame on (ps2c, ps2d) plus a [done_] pop,
   and records per cycle the inputs it drove and the [rdy] it observed. The Verilator
   harness (test/cosim/ps2.cpp) does a fixed-length replay of the identical (ps2c, ps2d,
   done_) waveform through test/_po/verilog/src/PS2.v and asserts, cycle-by-cycle, RTL rdy
   == port's, plus RTL data == the recovered byte whenever rdy is high.

   [shift] is ps2c-derived ([Q1 & ~Q0]) and trivially identical given the same ps2c, so it
   isn't in the trace; multi-byte FIFO ordering is covered by the co-located test. The
   FIFO pointers still advance (and wrap past 16) across these one-byte-per-line frames.

   Line format: "data hextrace" where data is the recovered byte (checked when rdy=1) and
   hextrace is one hex digit per cycle: bit3 = done_, bit2 = ps2c, bit1 = ps2d (the inputs
   driven), bit0 = rdy (the output checked). *)

open Hardcaml
open Cosim_dump
module Ps2 = Risc5.Ps2
module Sim = Cyclesim.With_interface (Ps2.I) (Ps2.O)

let h = 4 (* ps2c half-period in clocks (>=2 for the synchronizer to see the edge) *)

let odd_parity data =
  let ones = ref 0 in
  for j = 0 to 7 do
    ones := !ones + ((data lsr j) land 1)
  done;
  1 - (!ones land 1)
;;

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
    send_bit 0;
    for j = 0 to 7 do
      send_bit ((data lsr j) land 1)
    done;
    send_bit (odd_parity data);
    send_bit 1;
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
  let count = ref 0 in
  let emit ~data =
    let recv, trace = frame ~data in
    Printf.printf "%02X %s\n" recv trace;
    incr count
  in
  let corners = [ 0x00; 0xFF; 0xA5; 0x5A; 0x01; 0x80; 0x7F; 0x1C ] in
  List.iter (fun d -> emit ~data:d) corners;
  let rng = Random.State.make [| 0x732 |] in
  for _ = 1 to 40 do
    emit ~data:(Random.State.int rng 256)
  done;
  Printf.eprintf "ps2_dump: %d frames (8 corners + 40 fuzz)\n" !count
;;

(* RTL-fidelity dumper for the RS232 receiver. Like spi_dump/rs232t_dump it records a
   per-cycle hex trace, but the receiver is INPUT-driven: the dumper plays the sender,
   driving a UART frame on [rxd] (start, 8 data LSbit-first, stop) at the baud timing plus
   a [done_] ack, and records per cycle the inputs it drove and the [rdy] it observed. The
   matching Verilator harness (test/cosim/rs232r.cpp) replays the identical (rxd, done_)
   waveform through test/_po/verilog/src/RS232R.v and asserts, cycle-by-cycle, RTL rdy ==
   port's, plus RTL data == the recovered byte whenever rdy is high. Fully
   input-determined, so it's a fixed-length trace replay (no drain-until-rdy needed in the
   .cpp).

   Line format: "fsel data hextrace" where data is the recovered byte (checked when rdy=1)
   and hextrace is one hex digit per cycle: bit2 = done_, bit1 = rxd (the inputs driven),
   bit0 = rdy (the output checked). *)

open Hardcaml
open Cosim_dump
module Rs232r = Risc5.Rs232r
module Sim = Cyclesim.With_interface (Rs232r.I) (Rs232r.O)

let cap = 30000 (* safety: the slow frame is ~10 x 1303 cycles *)

let () =
  let sim = Sim.create Rs232r.create in
  let inp = (Cyclesim.inputs sim : _ Rs232r.I.t) in
  let outp = (Cyclesim.outputs sim : _ Rs232r.O.t) in
  (* reset (rst_n active-low, synchronous), line idle high; then frames back-to-back, each
     ending with a [done_] ack, exactly as the .cpp does. *)
  set inp.rst_n 0;
  set inp.rxd 1;
  set inp.fsel 0;
  set inp.done_ 0;
  Cyclesim.cycle sim;
  set inp.rst_n 1;
  Cyclesim.cycle sim;
  (* one frame: drive start + 8 data + stop on [rxd], drain to [rdy], capture data, ack
     with [done_]. Records per cycle (done_<<2 | rxd<<1 | rdy). Returns (recovered_byte,
     hextrace). *)
  let frame ~fsel ~data =
    let period = if fsel = 1 then 218 else 1303 in
    let buf = Buffer.create 4096 in
    let push () =
      let nib = (rd inp.done_ lsl 2) lor (rd inp.rxd lsl 1) lor rd outp.rdy in
      Buffer.add_char buf (hex_digit nib)
    in
    set inp.fsel fsel;
    let hold lvl =
      set inp.rxd lvl;
      for _ = 1 to period do
        Cyclesim.cycle sim;
        push ()
      done
    in
    hold 0;
    for j = 0 to 7 do
      hold ((data lsr j) land 1)
    done;
    hold 1;
    let n = ref 0 in
    while rd outp.rdy = 0 && !n < cap do
      Cyclesim.cycle sim;
      push ();
      incr n
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
  let emit ~fsel ~data =
    let recv, trace = frame ~fsel ~data in
    Printf.printf "%d %02X %s\n" fsel recv trace;
    incr count
  in
  (* corner bytes in both rates, then a fuzz pass biased to the cheap fast rate (fsel=1,
     ~2180 cy) over the slow rate (fsel=0, ~13030 cy). *)
  let corners = [ 0x00; 0xFF; 0xA5; 0x5A; 0x01; 0x80; 0x7F; 0xC3 ] in
  List.iter
    (fun d ->
      emit ~fsel:1 ~data:d;
      emit ~fsel:0 ~data:d)
    corners;
  let rng = Random.State.make [| 0x232 |] in
  for _ = 1 to 32 do
    emit ~fsel:1 ~data:(Random.State.int rng 256)
  done;
  for _ = 1 to 4 do
    emit ~fsel:0 ~data:(Random.State.int rng 256)
  done;
  Printf.eprintf "rs232r_dump: %d frames (corners x2 + 32 fast + 4 slow fuzz)\n" !count
;;

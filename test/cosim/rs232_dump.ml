(* RTL-fidelity dumper for the RS232 UART — both directions, selected by argv:
   [rs232_dump rs232t] (the transmitter) or [rs232_dump rs232r] (the receiver).

   The two share the test-vector driver ([drive]: the 8 corner bytes in both baud rates,
   then an rng-`0x232` fast/slow fuzz pass) and the reset/`emit` shape, but their
   per-frame protocol genuinely differs, so each keeps its own [frame]:

   - TX is a serial handshake (start/rdy), OUTPUT-only: drive (fsel, data), then record
     for EVERY cycle from [start] to [rdy] re-raising the (rdy, txd) observed. Line: "fsel
     data cycles hextrace", hextrace nibble = rdy<<1 | txd. No value column — [txd] IS the
     serialised value, checked each cycle.
   - RX is INPUT-driven: play the sender — hold a UART frame on [rxd] (start, 8 data
     LSbit-first, stop) at the baud period, drain to [rdy], capture the byte, ack with
     [done_] — recording per cycle the inputs driven + [rdy]. Line: "fsel data hextrace"
     (data = recovered byte, checked when rdy=1), hextrace nibble = done_<<2 | rxd<<1 |
     rdy.

   The matching Verilator harnesses (rs232t.cpp / rs232r.cpp) replay the identical
   stimulus through the reference RS232T.v / RS232R.v and assert cycle-by-cycle equality. *)

open Hardcaml
open Cosim_dump
module Rs232t = Risc5.Rs232t
module Rs232r = Risc5.Rs232r
module Sim_t = Cyclesim.With_interface (Rs232t.I) (Rs232t.O)
module Sim_r = Cyclesim.With_interface (Rs232r.I) (Rs232r.O)

(* shared stimulus: the 8 corner bytes in both rates, then a fuzz pass biased to the cheap
   fast rate (fsel=1) over the slow rate (fsel=0). The framing is data-independent in
   structure (only WHICH bits appear changes), so a modest spread across both rates
   exhausts the datapath. *)
let corners = [ 0x00; 0xFF; 0xA5; 0x5A; 0x01; 0x80; 0x7F; 0xC3 ]

let drive ~emit ~fast_n ~slow_n =
  List.iter
    (fun d ->
      emit ~fsel:1 ~data:d;
      emit ~fsel:0 ~data:d)
    corners;
  let rng = Random.State.make [| 0x232 |] in
  for _ = 1 to fast_n do
    emit ~fsel:1 ~data:(Random.State.int rng 256)
  done;
  for _ = 1 to slow_n do
    emit ~fsel:0 ~data:(Random.State.int rng 256)
  done
;;

(* ── transmitter ── *)
let tx_cap = 14000 (* safety: the slow frame is ~13030 cycles (10 bits x clk/1302) *)

let tx () =
  let sim = Sim_t.create Rs232t.create in
  let inp = (Cyclesim.inputs sim : _ Rs232t.I.t) in
  let outp = (Cyclesim.outputs sim : _ Rs232t.O.t) in
  (* reset (rst_n active-low, synchronous), then frames back-to-back: after each one the
     unit returns to rdy=1 / tick=0, so [start] re-arms it cleanly — exactly as the .cpp
     does. *)
  set inp.rst_n 0;
  set inp.start 0;
  set inp.fsel 0;
  set inp.data 0;
  Cyclesim.cycle sim;
  set inp.rst_n 1;
  Cyclesim.cycle sim;
  (* one frame: drive [start] for edge 0, then cycle until [rdy] re-raises, recording
     per-cycle (rdy, txd). Returns (cycles, hextrace); [cycles] = trace length = start to
     rdy re-raise. *)
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
    while !going && !n < tx_cap do
      Cyclesim.cycle sim;
      push ();
      incr n;
      if rd outp.rdy = 1 then going := false
    done;
    !n, Buffer.contents buf
  in
  let emit ~fsel ~data =
    let cycles, trace = frame ~fsel ~data in
    Printf.printf "%d %02X %d %s\n" fsel data cycles trace
  in
  drive ~emit ~fast_n:64 ~slow_n:8
;;

(* ── receiver ── *)
let rx_cap = 30000 (* safety: the slow frame is ~10 x 1303 cycles *)

let rx () =
  let sim = Sim_r.create Rs232r.create in
  let inp = (Cyclesim.inputs sim : _ Rs232r.I.t) in
  let outp = (Cyclesim.outputs sim : _ Rs232r.O.t) in
  (* reset, line idle high; then frames back-to-back, each ending with a [done_] ack. *)
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
    while rd outp.rdy = 0 && !n < rx_cap do
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
  let emit ~fsel ~data =
    let recv, trace = frame ~fsel ~data in
    Printf.printf "%d %02X %s\n" fsel recv trace
  in
  drive ~emit ~fast_n:32 ~slow_n:4
;;

let () =
  match Sys.argv with
  | [| _; "rs232t" |] -> tx ()
  | [| _; "rs232r" |] -> rx ()
  | _ ->
    Printf.eprintf "usage: rs232_dump <rs232t|rs232r>\n";
    exit 2
;;

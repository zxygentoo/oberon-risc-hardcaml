(* The dumper for the UART, in the direction given by its argument: [rs232_dump rs232t] or
   [rs232_dump rs232r]. Both use the same stimuli — eight corner bytes at both rates, then
   a seeded random pass — but their protocols differ:
   - the transmitter is driven with (fsel, data), and (rdy, txd) is recorded every cycle
     from [start] until [rdy] returns. Line: "fsel data cycles hextrace", a digit = rdy<<1
     | txd;
   - the receiver is fed a frame on [rxd] at the bit period, drained to [rdy], and
     acknowledged with [done_]; the inputs driven and [rdy] are recorded every cycle.
     Line: "fsel data hextrace", a digit = done_<<2 | rxd<<1 | rdy.

   rs232t.cpp and rs232r.cpp replay the same through RS232T.v and RS232R.v. *)

open Hardcaml
open Cosim_dump
module Uart_tx = Risc5.Uart_tx
module Uart_rx = Risc5.Uart_rx
module Sim_t = Cyclesim.With_interface (Uart_tx.I) (Uart_tx.O)
module Sim_r = Cyclesim.With_interface (Uart_rx.I) (Uart_rx.O)

(* the stimuli: eight corner bytes at both rates, then a random pass that favours the fast
   rate *)
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
  let sim = Sim_t.create Uart_tx.create in
  let inp = (Cyclesim.inputs sim : _ Uart_tx.I.t) in
  let outp = (Cyclesim.outputs sim : _ Uart_tx.O.t) in
  (* reset, then frames back to back, as in the .cpp *)
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
  let sim = Sim_r.create Uart_rx.create in
  let inp = (Cyclesim.inputs sim : _ Uart_rx.I.t) in
  let outp = (Cyclesim.outputs sim : _ Uart_rx.O.t) in
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

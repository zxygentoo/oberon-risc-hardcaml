(* The dumper for the SPI master. For each transfer it drives the port with (fast,
   data_tx) and a per-cycle MISO sequence, and records for every cycle the MISO it drove
   and the (rdy, sclk, mosi) it saw. spi.cpp replays the same through SPI.v and requires
   the same outputs every cycle, the same received data and the same length.

   MISO comes from a seeded generator, not from MOSI looped back: a stimulus independent
   of the unit's state cannot hide a bug in when MISO is sampled.

   Line: "fast data_tx data_rx cycles hextrace", one hex digit per cycle: bit 3 = MISO
   driven, bit 2 = rdy, bit 1 = sclk, bit 0 = mosi. *)

open Hardcaml
open Cosim_dump
module Spi = Risc5.Spi
module Sim = Cyclesim.With_interface (Spi.I) (Spi.O)

let cap = 700 (* safety: the slow byte is 512 cycles; no transfer should approach this *)

let () =
  let sim = Sim.create Spi.create in
  let inp = (Cyclesim.inputs sim : _ Spi.I.t) in
  let outp = (Cyclesim.outputs sim : _ Spi.O.t) in
  (* reset, then transfers back to back: after each the unit is idle again, as in the .cpp *)
  set inp.rst_n 0;
  set inp.start 0;
  set inp.fast 0;
  set inp.data_tx 0;
  set inp.miso 1;
  Cyclesim.cycle sim;
  set inp.rst_n 1;
  Cyclesim.cycle sim;
  let rng = Random.State.make [| 0x5C1 |] in
  let miso_bit () = Random.State.int rng 2 in
  (* one transfer: drive [start] for edge 0, then cycle (feeding a fresh random MISO each
     edge) until [rdy] re-raises, recording per-cycle (miso, rdy, sclk, mosi). Returns
     (data_rx, cycles, hextrace); [cycles] = trace length = edges from start to rdy. *)
  let transfer ~fast ~data_tx =
    let buf = Buffer.create 128 in
    let push miso =
      let nib =
        (miso lsl 3) lor (rd outp.rdy lsl 2) lor (rd outp.sclk lsl 1) lor rd outp.mosi
      in
      Buffer.add_char buf (hex_digit nib)
    in
    set inp.fast fast;
    set inp.data_tx data_tx;
    set inp.start 1;
    let m0 = miso_bit () in
    set inp.miso m0;
    Cyclesim.cycle sim;
    (* edge 0: start sampled (shreg<=data_tx, rdy<=0) *)
    push m0;
    set inp.start 0;
    let n = ref 1 in
    let going = ref true in
    while !going && !n < cap do
      let m = miso_bit () in
      set inp.miso m;
      Cyclesim.cycle sim;
      push m;
      incr n;
      if rd outp.rdy = 1 then going := false
    done;
    Bits.to_unsigned_int !(outp.data_rx), !n, Buffer.contents buf
  in
  let emit ~fast ~data_tx =
    let data_rx, cycles, trace = transfer ~fast ~data_tx in
    Printf.printf "%d %08X %08X %d %s\n" fast data_tx data_rx cycles trace
  in
  (* corner words in both modes, then a random pass that favours the cheap fast mode (96
     cycles, against 512 for a slow byte) *)
  let corners =
    [ 0x00000000
    ; 0xFFFFFFFF
    ; 0xA5A5A5A5
    ; 0x5A5A5A5A
    ; 0x12345678
    ; 0x80000000
    ; 0x00000001
    ; 0x7FFFFFFF
    ; 0xDEADBEEF
    ]
  in
  List.iter
    (fun d ->
      emit ~fast:0 ~data_tx:d;
      emit ~fast:1 ~data_tx:d)
    corners;
  for _ = 1 to 512 do
    emit ~fast:1 ~data_tx:(rand32 rng)
  done;
  for _ = 1 to 128 do
    emit ~fast:0 ~data_tx:(rand32 rng)
  done
;;

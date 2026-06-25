(* RTL-fidelity dumper for the SPI master. Unlike the FP units — a stall-based run ->
   drain -> z protocol, shared in dump_fp — the SPI is a serial peripheral with a
   start/rdy handshake and a per-cycle MISO input, so it gets its own dumper (reusing only
   cosim.h's tick on the C side).

   For each transfer it drives Risc5.Spi over (fast, data_tx) with a deterministic
   per-cycle MISO sequence and records, for EVERY cycle, the MISO it drove and the (rdy,
   sclk, mosi) it observed; the matching Verilator harness (test/cosim/spi.cpp) replays
   the identical (fast, data_tx, MISO sequence) through _po/verilog/src/SPI.v and asserts,
   cycle-by-cycle, RTL (rdy, sclk, mosi) == port's, plus final data_rx == port's and cycle
   count == port's — value-, waveform-, and cycle-fidelity, the serial-peripheral analog
   of the FP units' z + stall-length check.

   MISO is driven from an RNG (not looped back from MOSI): a fixed, DUT-independent
   stimulus decouples the input from internal state, so a bug in WHEN the port samples
   MISO can't hide behind "MISO happened to equal the bit we were shifting out anyway".

   Line format: "fast data_tx data_rx cycles hextrace" where hextrace is one hex digit per
   cycle: bit3 = MISO (the stimulus we drove), bit2 = rdy, bit1 = sclk, bit0 = mosi (the
   port outputs). The MISO sequence thus lives in the dump — the .cpp replays it, no
   shared RNG — and the per-cycle output bits are the expected values. *)

open Hardcaml
module Spi = Risc5.Spi
module Sim = Cyclesim.With_interface (Spi.I) (Spi.O)

(* set a 1- or 32-bit input ref to [v] at its own declared width *)
let set r v = r := Bits.of_unsigned_int ~width:(Bits.width !r) v

(* read a 1-bit output as 0/1 *)
let rd r = Bits.to_int_trunc !r
let cap = 700 (* safety: the slow byte is 512 cycles; no transfer should approach this *)

let () =
  let sim = Sim.create Spi.create in
  let inp = (Cyclesim.inputs sim : _ Spi.I.t) in
  let outp = (Cyclesim.outputs sim : _ Spi.O.t) in
  (* reset (rst_n active-low, synchronous), then run transfers back-to-back: after each
     one the unit returns to rdy=1 / tick=0, so [start] re-arms it cleanly — no
     per-transfer reset, exactly as the .cpp does. *)
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
      Buffer.add_char buf "0123456789ABCDEF".[nib]
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
  let count = ref 0 in
  let emit ~fast ~data_tx =
    let data_rx, cycles, trace = transfer ~fast ~data_tx in
    Printf.printf "%d %08X %08X %d %s\n" fast data_tx data_rx cycles trace;
    incr count
  in
  (* corner data words in both modes, then a random fuzz pass biased toward the cheap fast
     mode (96 cy) over the slow byte (512 cy). The SPI datapath is tiny and fully
     exercised per transfer, so a few hundred transfers covering both rates exhausts its
     behaviour. *)
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
  let rand32 () =
    (Random.State.int rng 0x10000 lsl 16) lor Random.State.int rng 0x10000
  in
  for _ = 1 to 512 do
    emit ~fast:1 ~data_tx:(rand32 ())
  done;
  for _ = 1 to 128 do
    emit ~fast:0 ~data_tx:(rand32 ())
  done;
  Printf.eprintf "dump_spi: %d transfers (corners x2 + 512 fast + 128 slow fuzz)\n" !count
;;

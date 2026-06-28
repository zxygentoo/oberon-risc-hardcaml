(* RTL-fidelity dumper for the PS/2 mouse. Plays a mouse device against the Hardcaml port
   (Risc5.Mouse) — the bidirectional init handshake to [run], then movement reports — and
   records, per cycle, the stimulus (rst_n + the device's open-drain pull-lows for
   msclk/msdat) and the port's outputs (msclk_oe, msdat_oe, out). The Verilator harness
   (test/cosim/mouse.cpp) replays the same stimulus through the real MousePM.v (wrapped by
   mouse_cosim.v) and asserts, every cycle, that the RTL's (msclk_oe, msdat_oe, out) ==
   the port's.

   Open-drain split: Hardcaml has no inout, so each line is a drive-low output [msclk_oe]
   / [msdat_oe] + a resolved input. Both sides resolve wire = ~(own DUT's oe | device
   pull-low); the device pull-low is what's dumped (it's the device's protocol decision),
   so each side feeds its own DUT a value consistent with that DUT's drive — a divergence
   shows up as an output mismatch.

   Line: "rstn dmc dmd mco mdo out7hex" per cycle. *)

open Hardcaml
open Cosim_dump
module Mouse = Risc5.Mouse
module Sim = Cyclesim.With_interface (Mouse.I) (Mouse.O)

let () =
  let sim = Sim.create Mouse.create in
  let inp = (Cyclesim.inputs sim : _ Mouse.I.t) in
  let outp = (Cyclesim.outputs sim : _ Mouse.O.t) in
  let bit1 b = Bits.of_unsigned_int ~width:1 (if b then 1 else 0) in
  let dev_msclk_low = ref false
  and dev_msdat_low = ref false in
  let cycles = ref 0 in
  (* open-drain wired-AND: each line = ~(host pulls low | device pulls low) *)
  let resolve () =
    inp.msclk := bit1 (not (rd outp.msclk_oe = 1 || !dev_msclk_low));
    inp.msdat := bit1 (not (rd outp.msdat_oe = 1 || !dev_msdat_low))
  in
  let cyc () =
    resolve ();
    Cyclesim.cycle sim;
    Printf.printf
      "%d %d %d %d %d %07x\n"
      (rd inp.rst_n)
      (if !dev_msclk_low then 1 else 0)
      (if !dev_msdat_low then 1 else 0)
      (rd outp.msclk_oe)
      (rd outp.msdat_oe)
      (rd outp.out);
    cycles := !cycles + 1
  in
  let wait_until cond cap =
    let g = ref 0 in
    while (not (cond ())) && !g < cap do
      cyc ();
      g := !g + 1
    done
  in
  (* one device clock pulse: high a few cycles, then low >9 (the 10-tap filter) so the DUT
     shifts *)
  let pulse () =
    dev_msclk_low := false;
    for _ = 1 to 6 do
      cyc ()
    done;
    dev_msclk_low := true;
    for _ = 1 to 16 do
      cyc ()
    done
  in
  let run () = (rd outp.out lsr 27) land 1 = 1 in
  inp.rst_n := bit1 true;
  inp.msclk := bit1 true;
  inp.msdat := bit1 true;
  (* INIT: clock each command through the request-to-send handshake *)
  let guard = ref 0 in
  while (not (run ())) && !guard < 8 do
    wait_until (fun () -> rd outp.msclk_oe = 1 || run ()) 60000;
    wait_until (fun () -> rd outp.msclk_oe = 0 || run ()) 60000;
    if not (run ())
    then (
      for _ = 1 to 25 do
        pulse ()
      done;
      dev_msclk_low := false;
      wait_until (fun () -> rd outp.msclk_oe = 1 || run ()) 60000);
    guard := !guard + 1
  done;
  (* REPORT: stream a few framed movement packets (start/8-data-LSB-first/odd-parity/stop) *)
  let parity b =
    let n = ref 0 in
    for i = 0 to 7 do
      n := !n + ((b lsr i) land 1)
    done;
    1 - (!n land 1)
  in
  let send_bit v =
    dev_msdat_low := not v;
    pulse ()
  in
  let send_byte b =
    send_bit false;
    for i = 0 to 7 do
      send_bit ((b lsr i) land 1 = 1)
    done;
    send_bit (parity b = 1);
    send_bit true
  in
  let xpos () = rd outp.out land 0x3FF in
  let send_report ~status ~mx ~my =
    let x0 = xpos () in
    send_byte status;
    send_byte mx;
    send_byte my;
    dev_msdat_low := false;
    wait_until (fun () -> xpos () <> x0) 40000
  in
  (* exercise +ve, -ve (sign bits), buttons, overflow — the report-decode corners *)
  send_report ~status:0x08 ~mx:3 ~my:5;
  send_report ~status:0x09 ~mx:0x7F ~my:1;
  (* Left button, large +X *)
  send_report ~status:0x30 ~mx:0xF0 ~my:0xF0;
  (* X/Y sign bits set (-ve moves) *)
  send_report ~status:0xC0 ~mx:0x11 ~my:0x22;
  (* X/Y overflow bits set *)
  Printf.eprintf "mouse_dump: %d cycles (init + 4 reports)\n" !cycles
;;

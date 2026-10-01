(* The dumper for the PS/2 mouse. A device model plays against the port — the
   initialisation handshake, then movement reports — and every cycle the stimulus (reset
   and the device's own pull-lows on the two lines) and the port's outputs are recorded.
   mouse.cpp replays the stimulus through MousePM.v, wrapped by mouse_cosim.v, and
   requires the same outputs every cycle.

   Each side resolves the open-drain lines itself, from its own design's drive and the
   device's pull-low. What is dumped is the device's pull-low, so a difference between the
   two designs shows as a difference in their outputs.

   Line, one per cycle: "rstn dmc dmd mco mdo out7hex". *)

open Hardcaml
open Cosim_dump
module Mouse = Risc5.Mouse
module Sim = Cyclesim.With_interface (Mouse.I) (Mouse.O)

let () =
  let sim = Sim.create Mouse.create in
  let inp = (Cyclesim.inputs sim : _ Mouse.I.t) in
  let outp = (Cyclesim.outputs sim : _ Mouse.O.t) in
  (* the device model is the design's own test double; here every clock is also dumped *)
  let module Device = Mouse.For_tests.Device in
  let dev =
    Device.attach sim ~on_cycle:(fun ~msclk_low ~msdat_low ->
      Printf.printf
        "%d %d %d %d %d %07x\n"
        (rd inp.rst_n)
        (Bool.to_int msclk_low)
        (Bool.to_int msdat_low)
        (rd outp.msclk_oe)
        (rd outp.msdat_oe)
        (rd outp.out))
  in
  Device.init dev;
  (* exercise +ve, -ve (sign bits), buttons, overflow — the report-decode corners *)
  Device.send_report dev ~status:0x08 ~mx:3 ~my:5;
  (* Left button, large +X *)
  Device.send_report dev ~status:0x09 ~mx:0x7F ~my:1;
  (* X/Y sign bits set (-ve moves) *)
  Device.send_report dev ~status:0x30 ~mx:0xF0 ~my:0xF0;
  (* X/Y overflow bits set *)
  Device.send_report dev ~status:0xC0 ~mx:0x11 ~my:0x22
;;

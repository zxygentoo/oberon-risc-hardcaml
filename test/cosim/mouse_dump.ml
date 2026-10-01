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

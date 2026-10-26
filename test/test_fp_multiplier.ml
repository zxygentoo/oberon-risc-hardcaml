(* The FP multiplier's values: every frozen M vector, then a fuzz against [Emu.Fp]. The
   emulator and FPMultiplier.v agree on every input, so nothing is skipped. *)

open Hardcaml
module Fp = Risc5.Fp_multiplier

let () =
  let module Sim = Cyclesim.With_interface (Fp.I) (Fp.O) in
  let sim = Sim.create Fp.create in
  let inp = (Cyclesim.inputs sim : _ Fp.I.t)
  and outp = (Cyclesim.outputs sim : _ Fp.O.t) in
  let run ~x ~y =
    Fp_replay.set inp.x x;
    Fp_replay.set inp.y y;
    Fp_replay.drive sim ~run:inp.run ~stall:outp.stall ~z:outp.z
  in
  Fp_replay.simple_value_test ~name:"fp-multiplier" ~tag:"M" ~run ~oracle:Emu.Fp.fp_mul
;;

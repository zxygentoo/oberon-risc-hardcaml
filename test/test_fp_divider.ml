(* Phase 3b — FPDivider value-correctness against the frozen fp_vectors (the always-on,
   Verilator-free behavioural layer; the RTL-fidelity co-sim in test/cosim/ is the
   separate, opt-in fidelity oracle — AGENT.md §6).

   Like FML and unlike the adder, FDV has no compiler-unreachable domain and no
   emulator-vs-RTL divergence (AGENT.md §8), so it needs no steering: replay every
   D-vector and fuzz against Emu.Fp via the shared [Fp_replay.simple_value_test]. *)

open Hardcaml
module Fp = Risc5.Fp_divider

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
  Fp_replay.simple_value_test ~name:"fp-divider" ~tag:"D" ~run ~oracle:Emu.Fp.fp_div
;;

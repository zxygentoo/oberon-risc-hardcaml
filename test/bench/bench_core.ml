(* Phase-9 core microbenchmark (AGENT.md §5) — the baseline cycle cost of the iterative
   MUL/DIV units, i.e. the measure-before-you-optimise gauge for the DSP-multiplier spike.

   It drives the real core white-box (the lockstep harness's trick: poke IR + the two
   operand registers, run to retirement) but *counts cycles* instead of checking the
   oracle. A multi-cycle op's cost is issue (1) + the unit's stall + commit (1); the stall
   is 33 for MUL/DIV today and is exactly what a DSP-backed multiply would cut, so the
   numbers below are the A/B baseline — re-run this after the swap and the stall column
   drops. A leading run=0 cycle clears the unit's state counter, mirroring the core's
   natural inter-op gap (a constant MUL stream would never reset S — see multiplier.mli).

   Standalone (no oracle / memory model). Run: dune exec test/bench_core.exe (or dune
   build @bench). Instruction encodings (RISC5.v fields p|q|u|v a b op .. c), all R1 := R2
   <op> R3 register form: ADD=0x01280003, MUL=0x012A0003, MUL'(u=1)=0x212A0003,
   DIV=0x012B0003. *)

open Hardcaml
module Core = Risc5.Risc5_core
module Sim = Cyclesim.With_interface (Core.I) (Core.O)

let () =
  let sim = Sim.create ~config:Cyclesim.Config.trace_all Core.create in
  let inp = Cyclesim.inputs sim in
  let some what = function
    | Some x -> x
    | None -> failwith ("bench: " ^ what ^ " not found by name")
  in
  let regfile = some "regfile" (Cyclesim.lookup_mem_by_name sim "regfile") in
  let reg_ir = some "ir" (Cyclesim.lookup_reg_by_name sim "ir") in
  let reg_pc = some "pc" (Cyclesim.lookup_reg_by_name sim "pc") in
  let stall = some "stall" (Cyclesim.lookup_node_by_name sim "stall") in
  let set r v w = r := Bits.of_unsigned_int ~width:w v in
  set inp.rst_n 1 1;
  set inp.stall_x 0 1;
  set inp.irq 0 1;
  set inp.codebus 0 32;
  set inp.inbus 0 32;
  (* one op to retirement; returns (total cycles, stall cycles) *)
  let run_op ~instr ~r2 ~r3 =
    Cyclesim.Reg.of_int reg_ir 0;
    Cyclesim.cycle sim (* clear the unit's S counter (run=0) *);
    Cyclesim.Memory.of_int regfile ~address:2 r2;
    Cyclesim.Memory.of_int regfile ~address:3 r3;
    Cyclesim.Reg.of_int reg_pc 0x1000;
    Cyclesim.Reg.of_int reg_ir instr;
    let total = ref 0
    and stall_c = ref 0 in
    Cyclesim.cycle sim;
    incr total (* issue *);
    while Cyclesim.Node.to_int stall = 1 do
      Cyclesim.cycle sim;
      incr total;
      incr stall_c
    done;
    Cyclesim.cycle sim;
    incr total (* commit *);
    !total, !stall_c
  in
  let report name ~instr ~r2 ~r3 =
    let total, stall_c = run_op ~instr ~r2 ~r3 in
    Printf.printf
      "  %-16s total=%3d   stall=%3d   overhead=%d\n"
      name
      total
      stall_c
      (total - stall_c)
  in
  Printf.printf "Phase-9 core microbench — baseline (iterative 33-cycle MUL/DIV)\n";
  Printf.printf "  per-op cycles through the core (issue + stall + commit):\n";
  report "ADD (1-cyc ref)" ~instr:0x0128_0003 ~r2:5 ~r3:7;
  report "MUL signed" ~instr:0x012A_0003 ~r2:0x1_2345 ~r3:0x6789;
  report "MUL' unsigned" ~instr:0x212A_0003 ~r2:0xFFFF_0001 ~r3:7;
  report "DIV" ~instr:0x012B_0003 ~r2:0x12_3456 ~r3:7;
  let mul_total, mul_stall = run_op ~instr:0x012A_0003 ~r2:3 ~r3:5 in
  let overhead = mul_total - mul_stall in
  Printf.printf
    "\n  projection — multiplier stall 33 -> K (issue/commit overhead %d holds):\n"
    overhead;
  List.iter
    (fun k ->
      let proj = overhead + k in
      Printf.printf
        "    K=%-2d -> %2d cycles/MUL   (%.1fx faster per MUL)\n"
        k
        proj
        (float mul_total /. float proj))
    [ 0; 1; 2; 3; 4 ]
;;

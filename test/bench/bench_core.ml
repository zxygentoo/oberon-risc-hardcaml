(* Phase-9 core microbenchmark (AGENT.md §5) — MUL/DIV cycles per op through the real
   core, iterative vs DSP multiplier, side by side.

   It drives the core white-box (the lockstep trick: poke IR + the two operand registers,
   run to retirement) and *counts cycles*: a multi-cycle op costs issue (1) + the unit's
   stall + commit (1). The DSP variant is swapped in through the core's existing
   [create_with_units] seam (just the [multiplier] field overridden to
   {!Multiplier.create_opt} — no core surgery), so this is a true A/B in one binary. A
   leading run=0 cycle clears the unit's state counter, mirroring the core's natural
   inter-op gap (a constant MUL stream would never reset S — see multiplier.mli). The
   integrated correctness line confirms the fast core isn't just faster but computes the
   same MUL result R1 as the proven one.

   Standalone (no oracle / memory model). Run: dune build @bench. Instruction encodings
   (RISC5.v fields p|q|u|v a b op .. c), all R1 := R2 <op> R3 register form:
   ADD=0x01280003, MUL=0x012A0003, MUL'(u=1)=0x212A0003, DIV=0x012B0003. *)

open Hardcaml
module Core = Risc5.Risc5_core
module Mul = Risc5.Multiplier
module Sim = Cyclesim.With_interface (Core.I) (Core.O)

(* build a core sim with the given build fn, time each op, print the per-op table, and
   return (signed-MUL total cycles, signed-MUL result R1) for the A/B + correctness line *)
let run_core ~label core_create =
  let sim = Sim.create ~config:Cyclesim.Config.trace_all core_create in
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
      "    %-16s total=%3d   stall=%3d   overhead=%d\n"
      name
      total
      stall_c
      (total - stall_c)
  in
  Printf.printf "  %s:\n" label;
  report "ADD (1-cyc ref)" ~instr:0x0128_0003 ~r2:5 ~r3:7;
  report "MUL signed" ~instr:0x012A_0003 ~r2:0x1_2345 ~r3:0x6789;
  report "MUL' unsigned" ~instr:0x212A_0003 ~r2:0xFFFF_0001 ~r3:7;
  report "DIV (iterative)" ~instr:0x012B_0003 ~r2:0x12_3456 ~r3:7;
  let mul_total, _ = run_op ~instr:0x012A_0003 ~r2:0x1_2345 ~r3:0x6789 in
  mul_total, Cyclesim.Memory.to_int regfile ~address:1
;;

let () =
  Printf.printf
    "Phase-9 core microbench — MUL/DIV cycles per op (issue + stall + commit)\n\n";
  let iter_mul, iter_r1 =
    run_core ~label:"iterative  (Multiplier.create — faithful, 33-cycle)" Core.create
  in
  Printf.printf "\n";
  (* swap only the multiplier via the core's existing units seam; everything else default *)
  let fast_units = { Core.Units.default with multiplier = (fun i -> Mul.create_opt i) } in
  let dsp_mul, dsp_r1 =
    run_core ~label:"DSP        (Multiplier.create_opt — combinational)" (fun i ->
      Core.create_with_units ~units:fast_units i)
  in
  Printf.printf
    "\n\
    \  A/B (MUL): %d → %d cycles  (%.1fx faster per MUL).  DIV unchanged (still \
     iterative).\n"
    iter_mul
    dsp_mul
    (float iter_mul /. float dsp_mul);
  Printf.printf
    "  integrated correctness: signed-MUL R1 = 0x%X (iter) vs 0x%X (dsp) → %s\n"
    iter_r1
    dsp_r1
    (if iter_r1 = dsp_r1 then "MATCH" else "*** MISMATCH ***")
;;

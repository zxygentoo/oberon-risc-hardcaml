(* The per-operation gauge: how many cycles one instruction takes through the real core
   under each choice of multipliers ({!Risc5.Cpu.multipliers}) — the iterative units, the
   combinational DSP products, and the 2-stage pipelined DSP products the board ships.

   It drives the core white-box, as the lockstep does: poke IR and the two operand
   registers, run to retirement, and count — a multi-cycle operation costs its issue
   cycle, the unit's stall, and the commit cycle. A cycle with no operation in IR comes
   first, which clears the unit's state counter as the gap between two instructions does
   in a running core.

   The three cores must also compute the same result for every operation; a mismatch fails
   the run. Standalone — no oracle, no memory model. Run: dune build @bench. *)

open Hardcaml
module Core = Risc5.Cpu
module Sim = Cyclesim.With_interface (Core.I) (Core.O)

(* register form, R1 := R2 <op> R3 (RISC5.v fields p|q|u|v a b op .. c) *)
let ops =
  [ "ADD", 0x0128_0003, 5, 7
  ; "MUL", 0x012A_0003, 0x1_2345, 0x6789
  ; "MUL' (unsigned)", 0x212A_0003, 0xFFFF_0001, 7
  ; "DIV", 0x012B_0003, 0x12_3456, 7
  ; "FML", 0x012E_0003, 0x4049_0FDB, 0x402D_F854 (* pi * e *)
  ]
;;

let cores : (string * Core.multipliers) list =
  [ "iterative", Iterative
  ; "DSP, combinational", Dsp { stages = 0 }
  ; "DSP, 2 stages", Dsp { stages = 2 }
  ]
;;

(* each operation's (cycles, R1) on a core built with [multipliers] *)
let time_ops multipliers =
  let sim =
    Sim.create ~config:Cyclesim.Config.trace_all (fun i -> Core.create ~multipliers i)
  in
  let inp = Cyclesim.inputs sim in
  let found what = function
    | Some x -> x
    | None -> failwith ("bench_core: " ^ what ^ " not found by name")
  in
  let regfile = found "regfile" (Cyclesim.lookup_mem_by_name sim "regfile")
  and ir = found "ir" (Cyclesim.lookup_reg_by_name sim "ir")
  and pc = found "pc" (Cyclesim.lookup_reg_by_name sim "pc")
  and stall = found "stall" (Cyclesim.lookup_node_or_reg_by_name sim "stall") in
  let set r v w = r := Bits.of_unsigned_int ~width:w v in
  set inp.rst_n 1 1;
  set inp.stall_x 0 1;
  set inp.irq 0 1;
  set inp.codebus 0 32;
  set inp.inbus 0 32;
  List.map
    (fun (_, instr, r2, r3) ->
      Cyclesim.Reg.of_int ir 0;
      Cyclesim.cycle sim;
      Cyclesim.Memory.of_int regfile ~address:2 r2;
      Cyclesim.Memory.of_int regfile ~address:3 r3;
      Cyclesim.Reg.of_int pc 0x1000;
      Cyclesim.Reg.of_int ir instr;
      let cycles = ref 1 in
      Cyclesim.cycle sim (* issue *);
      while Cyclesim.Node.to_int stall = 1 do
        Cyclesim.cycle sim;
        incr cycles
      done;
      Cyclesim.cycle sim (* commit *);
      !cycles + 1, Cyclesim.Memory.to_int regfile ~address:1)
    ops
;;

let () =
  let results = List.map (fun (_, multipliers) -> time_ops multipliers) cores in
  Printf.printf "Cycles per operation through the core (issue + stall + commit):\n\n";
  Printf.printf "  %-18s" "";
  List.iter (fun (name, _) -> Printf.printf "%20s" name) cores;
  Printf.printf "\n";
  let agree = ref true in
  List.iteri
    (fun k (op, _, _, _) ->
      let row = List.map (fun r -> List.nth r k) results in
      Printf.printf "  %-18s" op;
      List.iter (fun (cycles, _) -> Printf.printf "%20d" cycles) row;
      let _, r1 = List.hd row in
      if List.for_all (fun (_, r) -> r = r1) row
      then Printf.printf "    R1 = 0x%08X on all three\n" r1
      else (
        agree := false;
        Printf.printf
          "    *** RESULTS DIFFER: %s ***\n"
          (String.concat " / " (List.map (fun (_, r) -> Printf.sprintf "0x%08X" r) row))))
    ops;
  if not !agree then exit 1
;;

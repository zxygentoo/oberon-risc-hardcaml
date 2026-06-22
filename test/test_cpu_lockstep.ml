(* Phase 4.1/4.2 — single-instruction lockstep for the register ops (AGENT.md §6, layer
   4).

   Drive a random register-op instruction into the Hardcaml core and the OCaml oracle, one
   instruction each, and assert the architectural state (the 16 registers, the N/Z/C/OV
   flags, PC, and the aux register H) matches. Cases are isolated — a fresh random
   [{regs, flags, H, instruction}] is poked into both machines, run to completion, and
   compared — so coverage doesn't depend on a boot sequence and §8 steering is decided per
   case.

   The Hardcaml core's state is reached through Cyclesim by-name lookups (the [create]
   harness): the register file is a named [multiport_memory], pc/ir/flags/h are named (--)
   register outputs, "stall" a named node. The oracle uses its [For_tests] white-box
   pokes.

   Scope: ops 0..15. Steering (§8) — all unreachable from compiled Oberon-07, so we follow
   the hardware: the ADD'/SUB' carry corner, the unsigned MUL' high word, the DIV 0<y<2^31
   precondition, and FP forced register-register (FLT/FLOOR are covered by the FP-unit
   tests). See [steered] below. *)

open Hardcaml
module Core = Risc5.Risc5_core
module R = Oracle.Risc
module Sim = Cyclesim.With_interface (Core.I) (Core.O)

(* a word index safely inside RAM (< mem_size/4) so the oracle fetches from ram.(pc) *)
let base_pc = 0x1000

(* ─── Harness: the Hardcaml core sim + the OCaml oracle, with the by-name handles used to
   poke and read each machine's architectural state. The [reg_]/[regfile]/[stall] handles
   are named so they don't collide with the [case] fields below. ─── *)
type t =
  { sim : Sim.t
  ; regfile : Cyclesim.Memory.t
  ; reg_ir : Cyclesim.Reg.t
  ; reg_pc : Cyclesim.Reg.t
  ; reg_n : Cyclesim.Reg.t
  ; reg_z : Cyclesim.Reg.t
  ; reg_c : Cyclesim.Reg.t
  ; reg_ov : Cyclesim.Reg.t
  ; reg_h : Cyclesim.Reg.t
  ; stall : Cyclesim.Node.t
  ; oracle : R.t
  }

let create () =
  let sim = Sim.create ~config:Cyclesim.Config.trace_all Core.create in
  let inp = Cyclesim.inputs sim in
  let some what = function
    | Some x -> x
    | None -> failwith ("lockstep: " ^ what ^ " not found by name")
  in
  let reg name = some name (Cyclesim.lookup_reg_by_name sim name) in
  inp.rst_n := Bits.of_unsigned_int ~width:1 1;
  inp.stall_x := Bits.of_unsigned_int ~width:1 0;
  inp.codebus := Bits.of_unsigned_int ~width:32 0;
  { sim
  ; regfile = some "regfile" (Cyclesim.lookup_mem_by_name sim "regfile")
  ; reg_ir = reg "ir"
  ; reg_pc = reg "pc"
  ; reg_n = reg "n"
  ; reg_z = reg "z"
  ; reg_c = reg "c"
  ; reg_ov = reg "ov"
  ; reg_h = reg "h"
  ; stall = some "stall" (Cyclesim.lookup_node_by_name sim "stall")
  ; oracle = R.make ()
  }
;;

(* one register-op instruction + the architectural state to run it from *)
type case =
  { regs : int array
  ; n : int
  ; z : int
  ; c : int
  ; ov : int
  ; h : int
  ; op : int
  ; instr : int
  }

(* the flags as the oracle / cpu_state pack them: Z | N<<1 | C<<2 | V<<3 *)
let packed_flags ~n ~z ~c ~ov = z lor (n lsl 1) lor (c lsl 2) lor (ov lsl 3)

(* run [case] on the Hardcaml core and read back (regs, flags, pc, h). Single-cycle ops
   (0..9) take one cycle; multi-cycle ops (10..15) run until the unit's "stall" drops,
   then one more cycle commits the writeback (regwr = ~p & ~stall fires only once stall
   drops). The leading run=0 cycle clears the units' (reset-less, run-gated) state
   counters. *)
let step_core t { regs; n; z; c; ov; h; op; instr } =
  Cyclesim.Reg.of_int t.reg_ir 0;
  Cyclesim.cycle t.sim;
  Array.iteri (fun k v -> Cyclesim.Memory.of_int t.regfile ~address:k v) regs;
  Cyclesim.Reg.of_int t.reg_n n;
  Cyclesim.Reg.of_int t.reg_z z;
  Cyclesim.Reg.of_int t.reg_c c;
  Cyclesim.Reg.of_int t.reg_ov ov;
  Cyclesim.Reg.of_int t.reg_h h;
  Cyclesim.Reg.of_int t.reg_ir instr;
  Cyclesim.Reg.of_int t.reg_pc base_pc;
  if op < 10
  then Cyclesim.cycle t.sim
  else (
    Cyclesim.cycle t.sim;
    while Cyclesim.Node.to_int t.stall = 1 do
      Cyclesim.cycle t.sim
    done;
    Cyclesim.cycle t.sim);
  let regs = Array.init 16 (fun k -> Cyclesim.Memory.to_int t.regfile ~address:k) in
  let flags =
    packed_flags
      ~n:(Cyclesim.Reg.to_int t.reg_n)
      ~z:(Cyclesim.Reg.to_int t.reg_z)
      ~c:(Cyclesim.Reg.to_int t.reg_c)
      ~ov:(Cyclesim.Reg.to_int t.reg_ov)
  in
  regs, flags, Cyclesim.Reg.to_int t.reg_pc, Cyclesim.Reg.to_int t.reg_h
;;

(* run [case] on the oracle and read back the same (regs, flags, pc, h) tuple *)
let step_oracle t { regs; n; z; c; ov; h; instr; op = _ } =
  let oregs = R.For_tests.regs t.oracle in
  Array.iteri (fun k v -> oregs.(k) <- v) regs;
  R.For_tests.set_flags t.oracle (packed_flags ~n ~z ~c ~ov);
  R.For_tests.set_h t.oracle h;
  R.For_tests.set_pc t.oracle base_pc;
  (R.For_tests.ram t.oracle).(base_pc) <- instr;
  R.For_tests.single_step t.oracle;
  ( R.For_tests.regs t.oracle
  , R.For_tests.flags t.oracle
  , R.For_tests.pc t.oracle
  , R.For_tests.h t.oracle )
;;

(* do the two machines agree on the full architectural state after [case]? *)
let agree t case =
  let hw_regs, hw_flags, hw_pc, hw_h = step_core t case in
  let or_regs, or_flags, or_pc, or_h = step_oracle t case in
  let regs_eq = ref true in
  for k = 0 to 15 do
    if hw_regs.(k) <> or_regs.(k) then regs_eq := false
  done;
  !regs_eq && hw_flags = or_flags && hw_pc = or_pc && hw_h = or_h
;;

(* ─── Generating a random register-op case ─── *)

(* QCheck's int32 gives full 32-bit coverage with edge cases + shrinking; reinterpret as
   an unsigned 32-bit word *)
let u32 (x : int32) = Int32.to_int x land 0xFFFF_FFFF

(* decode a raw QCheck draw into a [case]: a register-op instruction word (p=0), two
   operand values placed at its source registers R[irb]/R[irc], the flags, and H. FP (op
   12..15) is forced register-register (q=u=v=0). *)
let decode (instr31, ob32, oc32, flags4, h32) =
  let op = (instr31 lsr 16) land 0xF in
  let instr = if op >= 12 then instr31 land lnot 0x7000_0000 else instr31 in
  let irb = (instr lsr 20) land 0xF
  and irc = instr land 0xF in
  let regs = Array.make 16 0 in
  regs.(irb) <- u32 ob32;
  regs.(irc) <- u32 oc32 (* if irb=irc, R holds oc (placed last), identically in both *);
  { regs
  ; op
  ; instr
  ; n = (flags4 lsr 1) land 1
  ; z = flags4 land 1
  ; c = (flags4 lsr 2) land 1
  ; ov = (flags4 lsr 3) land 1
  ; h = u32 h32
  }
;;

(* the §8 corners / unit preconditions, all unreachable from compiled Oberon (we follow
   the hardware), steered out per case: the ADD'/SUB' carry corner (2nd operand 0xFFFFFFFF
   with carry-in), the unsigned MUL' high word (sign-extended operand, C1[31]=1), and the
   DIV precondition (the restoring divider needs 0 < y < 2^31). *)
let steered { op; instr; regs; c; _ } =
  let q = (instr lsr 30) land 1
  and u = (instr lsr 29) land 1
  and v = (instr lsr 28) land 1
  and imm = instr land 0xFFFF
  and irc = instr land 0xF in
  let c1 = if q = 1 then if v = 1 then 0xFFFF_0000 lor imm else imm else regs.(irc) in
  let c1_neg = (c1 lsr 31) land 1 = 1 in
  ((op = 8 || op = 9) && u = 1 && c = 1 && c1 = 0xFFFF_FFFF)
  || (op = 10 && u = 1 && c1_neg)
  || (op = 11 && (c1 = 0 || c1_neg))
;;

let arbitrary =
  QCheck.set_print
    (fun (instr31, ob, oc, f, h) ->
      Printf.sprintf
        "instr31=%08x op_b=%08lx op_c=%08lx flags=%x h=%08lx"
        instr31
        ob
        oc
        f
        h)
    (QCheck.tup5
       (QCheck.int_bound 0x7FFF_FFFF)
       QCheck.int32
       QCheck.int32
       (QCheck.int_bound 15)
       QCheck.int32)
;;

let () =
  let t = create () in
  (* int32 boundary coverage + shrinking minimizes a failure to a small instruction +
     operands; ~max_gen above ~count absorbs the §8 [assume] discards (~5%) *)
  QCheck.Test.check_exn
    (QCheck.Test.make
       ~count:50_000
       ~max_gen:60_000
       ~name:"cpu register-op lockstep (ops 0..15)"
       arbitrary
       (fun raw ->
          let case = decode raw in
          QCheck.assume (not (steered case));
          agree t case));
  Printf.printf "cpu lockstep (register ops 0..15): 50000 QCheck cases, passed\n"
;;

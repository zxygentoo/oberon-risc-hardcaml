(* Phase 4.1 — single-instruction lockstep for register ALU ops (AGENT.md §6, layer 4).

   The first whole-core differential test: drive a random register-op instruction into the
   Hardcaml core *and* the OCaml oracle, one instruction each, and assert the
   architectural state (the 16 registers, the N/Z/C/OV flags, and PC) matches. Cases are
   isolated — each pokes a fresh random [{regs, flags, instruction, pc}] into both
   machines, steps one instruction, and compares — so coverage doesn't depend on a boot
   sequence and §8 steering is decided per case.

   Mechanics. The oracle exposes white-box pokes
   (For_tests.[{regs,set_flags,set_pc,ram, single_step}]). The Hardcaml core's state is
   reached through Cyclesim's by-name lookups: the register file is a named
   [multiport_memory] ("regfile"), and pc / ir / n / z / c / ov are named (--) register
   outputs. We poke ir directly (no fetch), poke the operands and flags, run one
   [Cyclesim.cycle] (which commits the writeback, flag update, and pc+1 at the edge), then
   read the post-edge regfile / flags / pc back.

   Scope: the *wired* register ops, op 0..9 — MOV, the shifts (LSL/ASR/ROR), the logic ops
   (AND/ANN/IOR/XOR), and ADD/SUB. The multi-cycle ops 10..15 (MUL/DIV/FP) read 0 in the
   4.1 result mux, so they're out of scope until 4.2.

   Steering (§8). The lone reachable emulator-vs-RTL divergence among ops 0..9 is the
   ADD'/SUB' carry-in corner: when the second operand is 0xFFFFFFFF and there's a carry-in
   (u=1, C=1), the oracle's compare-derived C differs from the faithful adder's. We follow
   the hardware, so we skip exactly that case. (The MOV' flags-read 0x53 id byte is now
   oracle-direct — both sides emit 0x53 — so it needs no steer and is checked here.) *)

open Hardcaml
module Core = Risc5.Risc5_core
module R = Oracle.Risc

let () =
  let module Sim = Cyclesim.With_interface (Core.I) (Core.O) in
  let sim = Sim.create ~config:Cyclesim.Config.trace_all Core.create in
  let inp = (Cyclesim.inputs sim : _ Core.I.t) in
  let regfile =
    match Cyclesim.lookup_mem_by_name sim "regfile" with
    | Some m -> m
    | None -> failwith "regfile memory not found by name"
  in
  let reg name =
    match Cyclesim.lookup_reg_by_name sim name with
    | Some r -> r
    | None -> failwith ("register not found by name: " ^ name)
  in
  let hw_ir = reg "ir"
  and hw_pc = reg "pc"
  and hw_n = reg "n"
  and hw_z = reg "z"
  and hw_c = reg "c"
  and hw_ov = reg "ov" in
  (* the core is never in reset and never externally stalled during the test *)
  inp.rst_n := Bits.of_unsigned_int ~width:1 1;
  inp.stall_x := Bits.of_unsigned_int ~width:1 0;
  inp.codebus := Bits.of_unsigned_int ~width:32 0;
  let oracle = R.make () in
  (* a word index safely inside RAM (< mem_size/4) so the oracle fetches from ram.(pc) *)
  let base_pc = 0x1000 in
  (* run [instr] on both machines from arch state [{regs, n,z,c,ov}]; return (agree?, hw,
     or) where each snapshot is (regs, packed-flags, pc) *)
  let run_one ~regs ~n ~z ~c ~ov ~instr =
    (* Hardcaml: poke -> one cycle -> read post-edge *)
    Array.iteri (fun k v -> Cyclesim.Memory.of_int regfile ~address:k v) regs;
    Cyclesim.Reg.of_int hw_n n;
    Cyclesim.Reg.of_int hw_z z;
    Cyclesim.Reg.of_int hw_c c;
    Cyclesim.Reg.of_int hw_ov ov;
    Cyclesim.Reg.of_int hw_ir instr;
    Cyclesim.Reg.of_int hw_pc base_pc;
    Cyclesim.cycle sim;
    let hw_regs = Array.init 16 (fun k -> Cyclesim.Memory.to_int regfile ~address:k) in
    let hw_pc' = Cyclesim.Reg.to_int hw_pc in
    let hw_flags =
      Cyclesim.Reg.to_int hw_z
      lor (Cyclesim.Reg.to_int hw_n lsl 1)
      lor (Cyclesim.Reg.to_int hw_c lsl 2)
      lor (Cyclesim.Reg.to_int hw_ov lsl 3)
    in
    (* oracle: poke -> single_step -> read (flags packed Z|N<<1|C<<2|V<<3) *)
    let oregs = R.For_tests.regs oracle in
    Array.iteri (fun k v -> oregs.(k) <- v) regs;
    R.For_tests.set_flags oracle (z lor (n lsl 1) lor (c lsl 2) lor (ov lsl 3));
    R.For_tests.set_h oracle 0;
    R.For_tests.set_pc oracle base_pc;
    (R.For_tests.ram oracle).(base_pc) <- instr;
    R.For_tests.single_step oracle;
    let or_regs = Array.copy (R.For_tests.regs oracle) in
    let or_flags = R.For_tests.flags oracle in
    let or_pc = R.For_tests.pc oracle in
    let regs_ok = ref true in
    for k = 0 to 15 do
      if hw_regs.(k) <> or_regs.(k) then regs_ok := false
    done;
    ( !regs_ok && hw_flags = or_flags && hw_pc' = or_pc
    , (hw_regs, hw_flags, hw_pc')
    , (or_regs, or_flags, or_pc) )
  in
  let rng = Random.State.make [| 0x4151_5253 |] in
  (* boundary values — where ADD/SUB carry/overflow and the §8 carry corner live *)
  let edges =
    [| 0; 1; 2; 0xFFFF; 0x1_0000; 0x7FFF_FFFF; 0x8000_0000; 0xFFFF_FFFF; 0xFFFF_FFFE |]
  in
  let rand32 () =
    if Random.State.int rng 4 = 0
    then edges.(Random.State.int rng (Array.length edges))
    else Random.State.int rng 0x10000 lor (Random.State.int rng 0x10000 lsl 16)
  in
  let bit () = Random.State.int rng 2 in
  let nyb () = Random.State.int rng 16 in
  let fails = ref 0
  and n_cases = ref 0
  and skipped = ref 0 in
  let one () =
    let regs = Array.init 16 (fun _ -> rand32 ()) in
    let n = bit ()
    and z = bit ()
    and c = bit ()
    and ov = bit () in
    let q = bit ()
    and u = bit ()
    and v = bit () in
    let a = nyb ()
    and b = nyb ()
    and creg = nyb () in
    let op = Random.State.int rng 10 (* 0..9: the wired register ops; 10..15 are 4.2 *) in
    let imm = Random.State.int rng 0x10000 in
    let lo16 = if q = 1 then imm else creg in
    let instr =
      (q lsl 30)
      lor (u lsl 29)
      lor (v lsl 28)
      lor (a lsl 24)
      lor (b lsl 20)
      lor (op lsl 16)
      lor lo16
    in
    (* §8 steer: the ADD'/SUB' carry-in corner (2nd operand 0xFFFFFFFF with carry-in) *)
    let c1 = if q = 1 then if v = 1 then 0xFFFF_0000 lor imm else imm else regs.(creg) in
    let carry_corner = (op = 8 || op = 9) && u = 1 && c = 1 && c1 = 0xFFFF_FFFF in
    if carry_corner
    then incr skipped
    else (
      incr n_cases;
      let ok, (hwr, hwf, hwp), (orr, orf, orp) = run_one ~regs ~n ~z ~c ~ov ~instr in
      if not ok
      then (
        incr fails;
        if !fails <= 10
        then (
          Printf.printf
            "FAIL instr=%08X op=%d q=%d u=%d v=%d a=%d b=%d c/imm=%d | flags in n%d z%d \
             c%d ov%d\n"
            instr
            op
            q
            u
            v
            a
            b
            lo16
            n
            z
            c
            ov;
          Printf.printf "  pc hw=%X or=%X   flags hw=%X or=%X\n" hwp orp hwf orf;
          for k = 0 to 15 do
            if hwr.(k) <> orr.(k)
            then Printf.printf "  R%-2d hw=%08X or=%08X\n" k hwr.(k) orr.(k)
          done)))
  in
  for _ = 1 to 50_000 do
    one ()
  done;
  Printf.printf
    "cpu lockstep (register ops 0..9): %d cases, %d skipped (§8 carry corner), %d fail\n"
    !n_cases
    !skipped
    !fails;
  if !fails > 0 then exit 1
;;

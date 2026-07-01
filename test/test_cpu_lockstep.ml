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
  ; inbus : Bits.t ref (* load-data input port *)
  ; out_pre : Bits.t ref Core.O.t
  (* outputs sampled before the edge — to catch a store's adr/wr/outbus on its [stallL0]
     cycle *)
  }

(* [?core] swaps the core constructor so the same harness can lockstep a variant build —
   e.g. the Phase-9 [~fast_mul ~mul_stages:2] pipelined-DSP core (see the runner).
   Defaults to the faithful [Core.create]; eta-expanded to erase its optional args to the
   plain [_ I.t -> _ O.t] the simulator wants. *)
let create ?(core = fun i -> Core.create i) () =
  let sim = Sim.create ~config:Cyclesim.Config.trace_all core in
  let inp = Cyclesim.inputs sim in
  let some what = function
    | Some x -> x
    | None -> failwith ("lockstep: " ^ what ^ " not found by name")
  in
  let reg name = some name (Cyclesim.lookup_reg_by_name sim name) in
  inp.rst_n := Bits.of_unsigned_int ~width:1 1;
  inp.stall_x := Bits.of_unsigned_int ~width:1 0;
  inp.codebus := Bits.of_unsigned_int ~width:32 0;
  { inbus = inp.inbus
  ; out_pre = Cyclesim.outputs ~clock_edge:Before sim
  ; sim
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

(* poke [case]'s arch state into the core, after a run=0 cycle that clears the units'
   state counters. (Does not cycle the instruction itself.) *)
let poke_core t { regs; n; z; c; ov; h; instr; op = _ } =
  Cyclesim.Reg.of_int t.reg_ir 0;
  Cyclesim.cycle t.sim;
  Array.iteri (fun k v -> Cyclesim.Memory.of_int t.regfile ~address:k v) regs;
  Cyclesim.Reg.of_int t.reg_n n;
  Cyclesim.Reg.of_int t.reg_z z;
  Cyclesim.Reg.of_int t.reg_c c;
  Cyclesim.Reg.of_int t.reg_ov ov;
  Cyclesim.Reg.of_int t.reg_h h;
  Cyclesim.Reg.of_int t.reg_ir instr;
  Cyclesim.Reg.of_int t.reg_pc base_pc
;;

(* read back the core's (regs, flags, pc, h) *)
let read_core t =
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

(* run [case] on the Hardcaml core (poke -> step -> read). Single-cycle ops (0..9) take
   one cycle; multi-cycle ops (10..15) run until the unit's "stall" drops, then one more
   cycle commits the writeback (regwr = ~p & ~stall fires only once stall drops). *)
let step_core t case =
  poke_core t case;
  if case.op < 10
  then Cyclesim.cycle t.sim
  else (
    Cyclesim.cycle t.sim;
    while Cyclesim.Node.to_int t.stall = 1 do
      Cyclesim.cycle t.sim
    done;
    Cyclesim.cycle t.sim);
  read_core t
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

let seed =
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

(* ─── Generating a random branch case ─── *)

(* decode a raw branch draw into a [case]. A branch is p=q=1; we keep the target in the
   in-range domain (§8 addressing): the register target R[irc] < 1 MB (so R[irc]>>2 stays
   in the oracle's RAM and within the core's 22-bit PC) and the relative disp small (so
   PC+1+disp neither wraps nor branches "into the void"). Register branches force
   IR[5:4]=0 to avoid the interrupt forms RTI/STI/CLI (4.5). [op]=0 selects the
   single-cycle path. *)
let decode_branch (bctrl, target32, disp, flags4) =
  let u = (bctrl lsr 29) land 1 in
  let irc = bctrl land 0xF in
  let ctrl = bctrl land 0x3F00_0000 (* u, v, neg, cc — bits 29..24 *) in
  let instr =
    if u = 1
    then
      (* relative: a sign-extended displacement. RISC5.v reads IR[21:0] (22-bit), the
         oracle reads IR[23:0] (24-bit); they agree only when IR[23:22] = sign(IR[21]), so
         we write the small disp across all 24 bits (the compiler likewise emits
         sign-extended offsets) *)
      0xC000_0000 lor ctrl lor (disp land 0xFF_FFFF)
    else 0xC000_0000 lor ctrl lor (bctrl land 0x000F_0000) lor irc
    (* register: irc in IR[3:0], IR[5:4]=0. We also scatter random bits into the op field
       IR[19:16] — unused by a branch, but it must stay inert: a branch ([p=1]) whose op
       field is 8/9 must NOT recompute/clobber C/OV (the [~p] qualifier). The compiler
       emits exactly such branches (e.g. [BLR] [0xDA08281C], op field 8); the old
       constrained disp / zero op-field kept this corner unreachable here, so the
       flag-leak escaped to boot. *)
  in
  let regs = Array.make 16 0 in
  regs.(irc) <- u32 target32 land 0xF_FFFF;
  { regs
  ; op = 0
  ; instr
  ; n = (flags4 lsr 1) land 1
  ; z = flags4 land 1
  ; c = (flags4 lsr 2) land 1
  ; ov = (flags4 lsr 3) land 1
  ; h = 0
  }
;;

let seed_branch =
  QCheck.set_print
    (fun (bctrl, target, disp, f) ->
      Printf.sprintf "bctrl=%08x target=%08lx disp=%d flags=%x" bctrl target disp f)
    (QCheck.tup4
       (QCheck.int_bound 0x3FFF_FFFF)
       QCheck.int32
       (QCheck.int_range (-0x800) 0x7FF)
       (QCheck.int_bound 15))
;;

(* register branch-and-link through R15 (u=0, v=1, irc=15): the RTL reads the OLD R15
   (async regfile read) as the target while linking the return address to R15 (sync write,
   same edge), so it jumps to the old R15; the oracle links first then reads the new R15,
   jumping to the link. We follow the hardware. Unreachable — the compiler never calls
   through the link register. *)
let steered_branch { instr; _ } =
  let u = (instr lsr 29) land 1
  and v = (instr lsr 28) land 1
  and irc = instr land 0xF in
  u = 0 && v = 1 && irc = 15
;;

(* ─── Loads ─── *)

(* run a load on both machines and compare (regs, flags, pc, h). The loaded word is
   presented on inbus and placed in the oracle's ram[adr_word]; a byte load selects the
   lane at adr[1:0] from that word, a word load takes it whole. The 2-cycle access writes
   R[a] on its stallL0 cycle, then the bubble advances PC. *)
let agree_load t ~case ~adr_word ~load_val =
  poke_core t case;
  t.inbus := Bits.of_unsigned_int ~width:32 load_val;
  Cyclesim.cycle t.sim;
  Cyclesim.cycle t.sim;
  let hw_regs, hw_flags, hw_pc, hw_h = read_core t in
  let oregs = R.For_tests.regs t.oracle in
  Array.iteri (fun k v -> oregs.(k) <- v) case.regs;
  R.For_tests.set_flags t.oracle (packed_flags ~n:case.n ~z:case.z ~c:case.c ~ov:case.ov);
  R.For_tests.set_h t.oracle case.h;
  R.For_tests.set_pc t.oracle base_pc;
  (R.For_tests.ram t.oracle).(base_pc) <- case.instr;
  (R.For_tests.ram t.oracle).(adr_word) <- load_val;
  R.For_tests.single_step t.oracle;
  let or_regs = R.For_tests.regs t.oracle in
  let regs_eq = ref true in
  for k = 0 to 15 do
    if hw_regs.(k) <> or_regs.(k) then regs_eq := false
  done;
  !regs_eq
  && hw_flags = R.For_tests.flags t.oracle
  && hw_pc = R.For_tests.pc t.oracle
  && hw_h = R.For_tests.h t.oracle
;;

(* a load draw: [ctrl] packs a/b/byte-mode/flags; [addr_byte] is the data address (kept in
   a small RAM region below the instruction at base_pc, so the oracle finds it in RAM and
   the word index never aliases base_pc); [off] is a small signed offset (we set R[b] =
   addr-off so R[b]+off lands on addr); [load_word] is what memory returns; [h] is the aux
   register. *)
let seed_load =
  QCheck.set_print
    (fun (ctrl, addr, off, w, h) ->
      Printf.sprintf "ctrl=%x addr=%x off=%d load=%08lx h=%08lx" ctrl addr off w h)
    (QCheck.tup5
       (QCheck.int_bound 0x1FFF)
       (QCheck.int_range 0x100 0x3C00)
       (QCheck.int_range (-0x40) 0x3F)
       QCheck.int32
       QCheck.int32)
;;

let decode_load (ctrl, addr_byte, off, load_word, h32) =
  let a = (ctrl lsr 9) land 0xF
  and b = (ctrl lsr 5) land 0xF
  and byte_mode = (ctrl lsr 4) land 1
  and flags = ctrl land 0xF in
  let regs = Array.make 16 0 in
  regs.(b) <- addr_byte - off (* R[b]; R[b]+off = addr_byte *);
  let instr =
    (* LDR: p=1,q=0,u=0, v=byte_mode, a=dest, b=base, off in IR[19:0] *)
    0x8000_0000
    lor (byte_mode lsl 28)
    lor (a lsl 24)
    lor (b lsl 20)
    lor (off land 0xF_FFFF)
  in
  let case =
    { regs
    ; op = 0
    ; instr
    ; n = (flags lsr 1) land 1
    ; z = flags land 1
    ; c = (flags lsr 2) land 1
    ; ov = (flags lsr 3) land 1
    ; h = u32 h32
    }
  in
  case, addr_byte lsr 2, u32 load_word
;;

(* ─── Stores ─── *)

(* run a store on both machines and compare. The core drives outbus/adr/wr on its stallL0
   cycle (captured pre-edge); we apply that to memory ([init_word] at adr_word, the
   addressed byte for a byte store) and compare with the oracle's ram[adr_word], plus the
   strobe/address and the (unchanged) regs/flags/pc/h. *)
let agree_store t ~case ~adr_word ~init_word ~byte_mode ~lane =
  poke_core t case;
  Cyclesim.cycle t.sim;
  let hw_adr = Bits.to_int_trunc !(t.out_pre.adr)
  and hw_wr = Bits.to_int_trunc !(t.out_pre.wr)
  and hw_outbus = Bits.to_int_trunc !(t.out_pre.outbus) in
  Cyclesim.cycle t.sim;
  let hw_regs, hw_flags, hw_pc, hw_h = read_core t in
  let hw_mem =
    if byte_mode = 1
    then
      init_word land lnot (0xFF lsl (8 * lane)) lor (hw_outbus land (0xFF lsl (8 * lane)))
    else hw_outbus
  in
  let oregs = R.For_tests.regs t.oracle in
  Array.iteri (fun k v -> oregs.(k) <- v) case.regs;
  R.For_tests.set_flags t.oracle (packed_flags ~n:case.n ~z:case.z ~c:case.c ~ov:case.ov);
  R.For_tests.set_h t.oracle case.h;
  R.For_tests.set_pc t.oracle base_pc;
  (R.For_tests.ram t.oracle).(base_pc) <- case.instr;
  (R.For_tests.ram t.oracle).(adr_word) <- init_word;
  R.For_tests.single_step t.oracle;
  let or_regs = R.For_tests.regs t.oracle in
  let regs_eq = ref true in
  for k = 0 to 15 do
    if hw_regs.(k) <> or_regs.(k) then regs_eq := false
  done;
  hw_wr = 1
  && hw_adr lsr 2 = adr_word
  && hw_mem = (R.For_tests.ram t.oracle).(adr_word)
  && !regs_eq
  && hw_flags = R.For_tests.flags t.oracle
  && hw_pc = R.For_tests.pc t.oracle
  && hw_h = R.For_tests.h t.oracle
;;

let seed_store =
  QCheck.set_print
    (fun (ctrl, addr, off, data, init) ->
      Printf.sprintf
        "ctrl=%x addr=%x off=%d data=%08lx init=%08lx"
        ctrl
        addr
        off
        data
        init)
    (QCheck.tup5
       (QCheck.int_bound 0x1FFF)
       (QCheck.int_range 0x100 0x3C00)
       (QCheck.int_range (-0x40) 0x3F)
       QCheck.int32
       QCheck.int32)
;;

let decode_store (ctrl, addr_byte, off, data, init32) =
  let a = (ctrl lsr 9) land 0xF
  and b = (ctrl lsr 5) land 0xF
  and byte_mode = (ctrl lsr 4) land 1
  and flags = ctrl land 0xF in
  let regs = Array.make 16 0 in
  regs.(a) <- u32 data (* R[a] = store data *);
  regs.(b) <- addr_byte - off (* R[b] = base (placed last, so a=b takes the base) *);
  let instr =
    (* STR: p=1,q=0,u=1, v=byte_mode, a=source, b=base, off in IR[19:0] *)
    0x8000_0000
    lor (1 lsl 29)
    lor (byte_mode lsl 28)
    lor (a lsl 24)
    lor (b lsl 20)
    lor (off land 0xF_FFFF)
  in
  let case =
    { regs
    ; op = 0
    ; instr
    ; n = (flags lsr 1) land 1
    ; z = flags land 1
    ; c = (flags lsr 2) land 1
    ; ov = (flags lsr 3) land 1
    ; h = 0
    }
  in
  case, addr_byte lsr 2, u32 init32, byte_mode, addr_byte land 3
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
       seed
       (fun raw ->
          let case = decode raw in
          QCheck.assume (not (steered case));
          agree t case));
  Printf.printf "cpu lockstep (register ops 0..15): 50000 QCheck cases, passed\n";
  (* branches reuse the same harness — no flags/regs written except a taken link, PC takes
     the target. The in-range domain and IR[5:4]=0 are baked into [decode_branch]; the
     lone §8 corner (BL through R15) is steered with [assume]. *)
  QCheck.Test.check_exn
    (QCheck.Test.make
       ~count:50_000
       ~max_gen:55_000
       ~name:"cpu branch lockstep (taken/not-taken, relative/register, link)"
       seed_branch
       (fun raw ->
          let case = decode_branch raw in
          QCheck.assume (not (steered_branch case));
          agree t case));
  Printf.printf "cpu lockstep (branches): 50000 QCheck cases, passed\n";
  (* loads: R[a] gets the byte-lane-selected / whole word from memory *)
  QCheck.Test.check_exn
    (QCheck.Test.make
       ~count:50_000
       ~name:"cpu load lockstep (word/byte)"
       seed_load
       (fun raw ->
          let case, adr_word, load_val = decode_load raw in
          agree_load t ~case ~adr_word ~load_val));
  Printf.printf "cpu lockstep (loads): 50000 QCheck cases, passed\n";
  (* stores: memory at adr gets A (word) or A[7:0] in the addressed lane (byte) *)
  QCheck.Test.check_exn
    (QCheck.Test.make
       ~count:50_000
       ~name:"cpu store lockstep (word/byte)"
       seed_store
       (fun raw ->
          let case, adr_word, init_word, byte_mode, lane = decode_store raw in
          agree_store t ~case ~adr_word ~init_word ~byte_mode ~lane));
  Printf.printf "cpu lockstep (stores): 50000 QCheck cases, passed\n";
  (* Phase-9 fast_mul, pipelined variant — re-run the register-op lockstep on a core with
     the 2-cycle *pipelined* DSP multipliers swapped in (Risc5_core.create ~fast_mul:true
     ~mul_stages:2). The units' z + stall are already proven bit-identical to the faithful
     multipliers by the co-located differential qcheck (lib/multiplier.ml,
     fp_multiplier.ml), which rides the Phase-8 proof transitively; that check drives the
     unit from a testbench that *mimics* the core's run/stall/operand-hold protocol. This
     closes the remaining sliver: it exercises the units under the *real* core's driving,
     over fuzzed operands broader than a boot stream — so the novel 2-cycle stall timing
     is verified in situ. MUL (op 10) and FML (op 14) hit the swapped units; the other ops
     run through the unchanged glue (harmless extra integration coverage). Bit-identical
     to the faithful path, the fast core diverges from the oracle in exactly the same §8
     corners, so [steered] is reused verbatim. The combinational create_opt (mul_stages:0)
     is left to differential qcheck + boot + visual-golden — its result is same-cycle, no
     stall timing to re-check. *)
  let t_fast = create ~core:(fun i -> Core.create ~fast_mul:true ~mul_stages:2 i) () in
  QCheck.Test.check_exn
    (QCheck.Test.make
       ~count:50_000
       ~max_gen:60_000
       ~name:"cpu register-op lockstep, fast_mul mul_stages:2 (pipelined DSP MUL/FML)"
       seed
       (fun raw ->
          let case = decode raw in
          QCheck.assume (not (steered case));
          agree t_fast case));
  Printf.printf
    "cpu lockstep (register ops, fast_mul mul_stages:2): 50000 QCheck cases, passed\n"
;;

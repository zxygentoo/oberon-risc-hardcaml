(* Single-instruction lockstep: the core against the oracle.

   A random instruction is run on the Hardcaml core and on the OCaml emulator, and the
   architectural state — the sixteen registers, the flags N/Z/C/OV, PC and H — must agree.
   Cases are isolated: a fresh random state and instruction are poked into both machines,
   run to completion and compared, so coverage does not depend on any boot sequence.

   The core's state is reached by name through Cyclesim (the register file is a named
   memory; pc, ir, the flags and h are named registers; [stall] a named node), the
   oracle's through its [For_tests] hooks.

   Covered: register operations 0..15, branches, loads and stores one instruction at a
   time, then short programs run from RAM under a random external stall. Where the oracle
   is known to differ from the RTL — every case unreachable from compiled Oberon — the
   port follows the hardware, and [authority] and [steered_branch] say what is done about
   each: the ADD'/SUB' carry corner and DIV outside its precondition y > 0 are skipped,
   the high word of an unsigned MUL' is compared with the hardware's own definition, and
   the FP operations are forced to their register form (FLT and FLOOR are covered by the
   FP tests). *)

open Hardcaml
module Core = Risc5.Cpu
module R = Emu.Risc
module Sim = Cyclesim.With_interface (Core.I) (Core.O)

(* a word index safely inside RAM (< mem_size/4) so the oracle fetches from ram.(pc) *)
let base_pc = 0x1000

(* ── The harness: the core's sim and the oracle, with the handles used to poke and read
   each ── *)
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

(* [?core] swaps the core's constructor, so that the same harness can check a variant,
   such as the core with the pipelined DSP multipliers. *)
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

(* build a [case], unpacking [flags] per the [packed_flags] layout — the single source of
   the flag-bit positions for every decoder below *)
let case_of ~regs ~op ~instr ~flags ~h =
  { regs
  ; op
  ; instr
  ; n = (flags lsr 1) land 1
  ; z = flags land 1
  ; c = (flags lsr 2) land 1
  ; ov = (flags lsr 3) land 1
  ; h
  }
;;

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

(* poke [case]'s arch state into the oracle (the mirror of [poke_core]; does not step) *)
let poke_oracle t { regs; n; z; c; ov; h; instr; op = _ } =
  let oregs = R.For_tests.regs t.oracle in
  Array.iteri (fun k v -> oregs.(k) <- v) regs;
  R.For_tests.set_flags t.oracle (packed_flags ~n ~z ~c ~ov);
  R.For_tests.set_h t.oracle h;
  R.For_tests.set_pc t.oracle base_pc;
  (R.For_tests.ram t.oracle).(base_pc) <- instr
;;

(* read back the oracle's (regs, flags, pc, h) *)
let read_oracle t =
  ( R.For_tests.regs t.oracle
  , R.For_tests.flags t.oracle
  , R.For_tests.pc t.oracle
  , R.For_tests.h t.oracle )
;;

(* full architectural agreement: the 16 registers, the packed flags, pc, and h *)
let state_eq (hw_regs, hw_flags, hw_pc, hw_h) (or_regs, or_flags, or_pc, or_h) =
  Array.for_all2 ( = ) hw_regs or_regs
  && hw_flags = or_flags
  && hw_pc = or_pc
  && hw_h = or_h
;;

(* run [case] on the oracle and read back the same (regs, flags, pc, h) tuple *)
let step_oracle t case =
  poke_oracle t case;
  R.For_tests.single_step t.oracle;
  read_oracle t
;;

(* The high word [Multiplier.v] produces for an unsigned multiply: its second operand is
   sign-extended regardless, so H is the high half of [b_unsigned * c1_signed]. The oracle
   multiplies unsigned by unsigned, which differs exactly when [c1] has bit 31 set. *)
let rtl_unsigned_mul_h ~b ~c1 =
  let c1_signed = Int64.of_int32 (Int32.of_int c1) in
  let product = Int64.mul (Int64.of_int b) c1_signed in
  Int64.to_int (Int64.shift_right_logical product 32) land 0xFFFF_FFFF
;;

(* the second ALU operand of a register op: the immediate (16 [v]-bits above it) or R.c *)
let operand_c1 ~instr ~regs =
  let q = (instr lsr 30) land 1
  and v = (instr lsr 28) land 1
  and imm = instr land 0xFFFF in
  if q = 1 then if v = 1 then 0xFFFF_0000 lor imm else imm else regs.(instr land 0xF)
;;

(* Where the oracle is not the authority for a register operation (all of it unreachable
   from compiled Oberon; the port follows the hardware):
   - [Skip]: ADD'/SUB' with carry-in and a second operand of 0xFFFFFFFF, where the
     oracle's carry-by-comparison is wrong; and DIV outside its precondition y > 0. The
     divider is defined for positive divisors only ([Divider.v] says so, and the compiler
     rejects a constant divisor that is not positive and traps on a variable one), so
     there is no result to agree on;
   - [Rtl_h h]: unsigned MUL' with C1[31] set. Everything but H is compared with the
     oracle, H with the value the hardware defines. *)
type authority =
  | Oracle
  | Skip
  | Rtl_h of int

let authority ~instr ~regs ~c =
  let op = (instr lsr 16) land 0xF
  and u = (instr lsr 29) land 1 in
  let c1 = operand_c1 ~instr ~regs in
  let c1_neg = (c1 lsr 31) land 1 = 1 in
  if (op = 8 || op = 9) && u = 1 && c = 1 && c1 = 0xFFFF_FFFF
  then Skip
  else if op = 11 && (c1 = 0 || c1_neg)
  then Skip
  else if op = 10 && u = 1 && c1_neg
  then Rtl_h (rtl_unsigned_mul_h ~b:regs.((instr lsr 20) land 0xF) ~c1)
  else Oracle
;;

(* do the two machines agree on the full architectural state after [case]? [expect]
   rewrites the oracle's result where the hardware is the authority. *)
let agree ?(expect = Fun.id) t case =
  let hw = step_core t case in
  state_eq hw (expect (step_oracle t case))
;;

let agree_reg_op t case =
  match authority ~instr:case.instr ~regs:case.regs ~c:case.c with
  | Skip -> QCheck.assume_fail ()
  | Oracle -> agree t case
  | Rtl_h h -> agree t case ~expect:(fun (regs, flags, pc, _) -> regs, flags, pc, h)
;;

(* ─── Generating a random register-op case ─── *)

module Gen = Risc5.Test_gen

(* decode a raw QCheck draw into a [case]: a register-op instruction word (p=0), two
   operand values placed at its source registers R[irb]/R[irc], the flags, and H. FP (op
   12..15) is forced register-register (q=u=v=0). *)
let decode (instr31, ob, oc, flags4, h) =
  let op = (instr31 lsr 16) land 0xF in
  let instr = if op >= 12 then instr31 land lnot 0x7000_0000 else instr31 in
  let irb = (instr lsr 20) land 0xF
  and irc = instr land 0xF in
  let regs = Array.make 16 0 in
  regs.(irb) <- ob;
  regs.(irc) <- oc (* if irb=irc, R holds oc (placed last), identically in both *);
  case_of ~regs ~op ~instr ~flags:flags4 ~h
;;

let seed =
  QCheck.set_print
    (fun (instr31, ob, oc, f, h) ->
      Printf.sprintf "instr31=%08x op_b=%08x op_c=%08x flags=%x h=%08x" instr31 ob oc f h)
    (QCheck.tup5
       (QCheck.int_bound 0x7FFF_FFFF)
       Gen.word32
       Gen.word32
       (QCheck.int_bound 15)
       Gen.word32)
;;

(* ─── Generating a random branch case ─── *)

(* A branch is p = q = 1. The target is kept in range: a register target below 1 MiB (so
   that it stays inside the oracle's RAM and the core's 22-bit PC) and a small relative
   displacement (so that PC + 1 + disp does not wrap). [op] = 0 selects the single-cycle
   path. *)
let decode_branch (bctrl, target, disp, flags4) =
  let u = (bctrl lsr 29) land 1
  and v = (bctrl lsr 28) land 1 in
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
    else (
      (* register: only IR[3:0] (the target register) means anything, so everything else
         in IR[23:4] is random and must stay inert — the op field (a branch whose op field
         is 8/9 must not touch C/OV: the [~p] qualifier; the compiler emits such branches,
         e.g. [BLR] [0xDA08281C]) and, for a linking branch, IR[5:4] too (RTI/STI/CLI are
         [~v] forms; that same BLR has IR[4] set). Without the link IR[5:4] = 0: those ARE
         the interrupt instructions, which the oracle does not model. *)
      let inert = bctrl land if v = 1 then 0x00FF_FFF0 else 0x00FF_FFC0 in
      0xC000_0000 lor ctrl lor inert lor irc)
  in
  let regs = Array.make 16 0 in
  regs.(irc) <- target land 0xF_FFFF;
  case_of ~regs ~op:0 ~instr ~flags:flags4 ~h:0
;;

let seed_branch =
  QCheck.set_print
    (fun (bctrl, target, disp, f) ->
      Printf.sprintf "bctrl=%08x target=%08x disp=%d flags=%x" bctrl target disp f)
    (QCheck.tup4
       (QCheck.int_bound 0x3FFF_FFFF)
       Gen.word32
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

(* ─── Loads and stores ─── *)

(* the bus strobes on the access's first (stallL0) cycle, sampled pre-edge *)
let bus_pre t =
  ( Bits.to_int_trunc !(t.out_pre.adr)
  , Bits.to_int_trunc !(t.out_pre.rd)
  , Bits.to_int_trunc !(t.out_pre.wr)
  , Bits.to_int_trunc !(t.out_pre.ben) )
;;

(* run a load on both machines and compare (regs, flags, pc, h), and the bus: the full
   byte address, rd without wr, and ben = the byte flag. The loaded word is presented on
   inbus and placed in the oracle's ram[adr_word]; a byte load selects the lane at
   adr[1:0] from that word, a word load takes it whole. The 2-cycle access writes R[a] on
   its stallL0 cycle, then the bubble advances PC. *)
let agree_load t ~case ~adr_byte ~byte_mode ~load_val =
  poke_core t case;
  t.inbus := Bits.of_unsigned_int ~width:32 load_val;
  Cyclesim.cycle t.sim;
  let bus = bus_pre t in
  Cyclesim.cycle t.sim;
  let hw = read_core t in
  poke_oracle t case;
  (R.For_tests.ram t.oracle).(adr_byte lsr 2) <- load_val;
  R.For_tests.single_step t.oracle;
  bus = (adr_byte, 1, 0, byte_mode) && state_eq hw (read_oracle t)
;;

(* a memory-access draw: [ctrl] packs a/b/byte-mode/flags; [addr_byte] is the data address
   (kept in a small RAM region below the instruction at base_pc, so the oracle finds it in
   RAM and the word index never aliases base_pc); [off] ranges over the whole signed
   20-bit offset field, and R[b] = addr - off (mod 2^32) so that R[b]+off lands on addr —
   a narrower sign-extension, or a carry lost above bit 15, lands somewhere else. *)
let seed_mem ~print_data =
  QCheck.set_print
    (fun (ctrl, addr, off, w, x) ->
      Printf.sprintf "ctrl=%x addr=%x off=%d %s=%08x %08x" ctrl addr off print_data w x)
    (QCheck.tup5
       (QCheck.int_bound 0x1FFF)
       (QCheck.int_range 0x100 0x3C00)
       (Gen.signed ~bits:20)
       Gen.word32
       Gen.word32)
;;

let seed_load = seed_mem ~print_data:"load"

let decode_load (ctrl, addr_byte, off, load_word, h) =
  let a = (ctrl lsr 9) land 0xF
  and b = (ctrl lsr 5) land 0xF
  and byte_mode = (ctrl lsr 4) land 1
  and flags = ctrl land 0xF in
  let regs = Array.make 16 0 in
  regs.(b) <- (addr_byte - off) land 0xFFFF_FFFF (* R[b]; R[b]+off = addr_byte *);
  let instr =
    (* LDR: p=1,q=0,u=0, v=byte_mode, a=dest, b=base, off in IR[19:0] *)
    0x8000_0000
    lor (byte_mode lsl 28)
    lor (a lsl 24)
    lor (b lsl 20)
    lor (off land 0xF_FFFF)
  in
  case_of ~regs ~op:0 ~instr ~flags ~h, byte_mode, load_word
;;

(* run a store on both machines and compare. The core drives outbus/adr/wr/ben on its
   stallL0 cycle (captured pre-edge); we apply that to memory ([init_word] at the
   addressed word, the lane [adr[1:0]] the core itself presents for a byte store) and
   compare with the oracle's ram, plus the bus (full byte address, wr without rd, ben) and
   the (unchanged) regs/flags/pc/h. *)
let agree_store t ~case ~adr_byte ~init_word ~byte_mode =
  poke_core t case;
  Cyclesim.cycle t.sim;
  let ((hw_adr, _, _, hw_ben) as bus) = bus_pre t
  and hw_outbus = Bits.to_int_trunc !(t.out_pre.outbus) in
  Cyclesim.cycle t.sim;
  let hw = read_core t in
  let hw_mem =
    if hw_ben = 1
    then (
      let lane_mask = 0xFF lsl (8 * (hw_adr land 3)) in
      init_word land lnot lane_mask lor (hw_outbus land lane_mask))
    else hw_outbus
  in
  let adr_word = adr_byte lsr 2 in
  poke_oracle t case;
  (R.For_tests.ram t.oracle).(adr_word) <- init_word;
  R.For_tests.single_step t.oracle;
  bus = (adr_byte, 0, 1, byte_mode)
  && hw_mem = (R.For_tests.ram t.oracle).(adr_word)
  && state_eq hw (read_oracle t)
;;

let seed_store = seed_mem ~print_data:"data"

let decode_store (ctrl, addr_byte, off, data, init) =
  let a = (ctrl lsr 9) land 0xF
  and b = (ctrl lsr 5) land 0xF
  and byte_mode = (ctrl lsr 4) land 1
  and flags = ctrl land 0xF in
  let regs = Array.make 16 0 in
  regs.(a) <- data (* R[a] = store data *);
  regs.(b) <- (addr_byte - off) land 0xFFFF_FFFF
  (* R[b] = base (placed last, so a=b takes the base) *);
  let instr =
    (* STR: p=1,q=0,u=1, v=byte_mode, a=source, b=base, off in IR[19:0] *)
    0x8000_0000
    lor (1 lsl 29)
    lor (byte_mode lsl 28)
    lor (a lsl 24)
    lor (b lsl 20)
    lor (off land 0xF_FFFF)
  in
  case_of ~regs ~op:0 ~instr ~flags ~h:0, init, byte_mode
;;

(* ─── Programs: several instructions back to back, under a stuttering stallX ───

   The single-instruction properties above start every case from a cleared core. This one
   runs a short random program from RAM, so instructions follow each other the way they do
   in real code — a multiply straight after a multiply, a load after a load, a branch
   deciding on the flags the previous instruction just set — while the external stall
   input is asserted at random. The core's bus is served by a small memory here, the same
   program runs on the oracle (which has no notion of a stall), and at the end the
   registers, flags, PC, H and the whole data region must agree. *)

let prog_len = 6
let pad = 3 (* a forward branch skips at most 2: the last one lands in the padding *)
let end_pc = base_pc + prog_len + pad
let data_reg = 13 (* base register of every load/store; nothing in a program writes it *)
let data_base = 0x2000 (* byte address held in R[data_reg] *)
let data_span = 0x400 (* loads/stores stay within data_base ± data_span *)
let data_lo = (data_base - data_span) lsr 2
let data_hi = (data_base + data_span) lsr 2

(* one raw draw -> one instruction word of a program *)
let prog_instr (kind, bits, off) =
  let a =
    let a = (bits lsr 24) land 0xF in
    if a = data_reg then data_reg - 1 else a
  in
  match kind with
  | 0 | 1 ->
    (* load / store through the data register *)
    0x8000_0000
    lor (kind lsl 29)
    lor (bits land 0x1000_0000 (* byte mode *))
    lor (a lsl 24)
    lor (data_reg lsl 20)
    lor (off land 0xF_FFFF)
  | 2 ->
    (* forward relative branch (any condition, with or without link) skipping 0..2 *)
    0xE000_0000 lor (bits land 0x1F00_0000) lor (bits land 0x3 mod 3)
  | _ ->
    (* register op, destination never the data register; FP forced register-register *)
    let op = (bits lsr 16) land 0xF in
    let w = bits land 0x70FF_FFFF lor (a lsl 24) in
    if op >= 12 then w land lnot 0x7000_0000 else w
;;

(* built at the generator level, so QCheck has no shrinker for it: the program, register
   and data lists are fixed-length by construction and must stay that way *)
let seed_prog =
  let open QCheck.Gen in
  let instr =
    triple
      (oneof_list_weighted [ 2, 0; 2, 1; 2, 2; 7, 3 ])
      (int_bound 0x7FFF_FFFF)
      (int_range (-data_span) (data_span - 1))
  in
  let word = QCheck.gen Gen.word32 in
  QCheck.make
    ~print:(fun (instrs, regs, (flags, h, stall_seed), data) ->
      Printf.sprintf
        "prog=[%s] regs=[%s] flags=%x h=%08x stall_seed=%d data=[%s]"
        (String.concat
           " "
           (List.map (fun i -> Printf.sprintf "%08x" (prog_instr i)) instrs))
        (String.concat " " (List.map (Printf.sprintf "%x") regs))
        flags
        h
        stall_seed
        (String.concat " " (List.map (Printf.sprintf "%x") data)))
    (quad
       (list_size (return prog_len) instr)
       (list_size (return 16) word)
       (triple (int_bound 15) word (int_bound 0xFFFF))
       (list_size (return 8) word))
;;

(* What the program property actually exercised, printed with its verdict — a property
   over generated programs is only as good as the programs, so say what they were. *)
type prog_stats =
  { mutable compared : int
  ; mutable discarded : int
  ; mutable instrs : int
  ; mutable loads : int
  ; mutable stores : int
  ; mutable taken : int (* branches taken *)
  ; mutable multi : int (* MUL/DIV/FP *)
  ; mutable multi_pairs : int (* a multi-cycle op directly after another *)
  ; mutable cycles : int
  ; mutable stalled : int
  }

let stats =
  { compared = 0
  ; discarded = 0
  ; instrs = 0
  ; loads = 0
  ; stores = 0
  ; taken = 0
  ; multi = 0
  ; multi_pairs = 0
  ; cycles = 0
  ; stalled = 0
  }
;;

let reset_stats () =
  stats.compared <- 0;
  stats.discarded <- 0;
  stats.instrs <- 0;
  stats.loads <- 0;
  stats.stores <- 0;
  stats.taken <- 0;
  stats.multi <- 0;
  stats.multi_pairs <- 0;
  stats.cycles <- 0;
  stats.stalled <- 0
;;

let print_stats () =
  let pct a b = if b = 0 then 0 else ((100 * a) + (b / 2)) / b in
  Printf.printf
    "  %d programs compared, %d discarded (known divergences); %d instructions: %d%% \
     loads, %d%% stores, %d%% taken branches, %d%% multi-cycle (%d back to back); %d%% \
     of %d cycles stalled\n\
     %!"
    stats.compared
    stats.discarded
    stats.instrs
    (pct stats.loads stats.instrs)
    (pct stats.stores stats.instrs)
    (pct stats.taken stats.instrs)
    (pct stats.multi stats.instrs)
    stats.multi_pairs
    (pct stats.stalled stats.cycles)
    stats.cycles
;;

(* would the instruction the oracle is about to execute leave the two machines apart for
   one of the known reasons? In a program any such step ends the comparison (a diverged H
   or carry feeds everything after it), so the case is discarded. *)
let oracle_next_is_steered t =
  let instr = (R.For_tests.ram t.oracle).(R.For_tests.pc t.oracle) in
  instr lsr 31 = 0
  &&
  match
    authority
      ~instr
      ~regs:(R.For_tests.regs t.oracle)
      ~c:((R.For_tests.flags t.oracle lsr 2) land 1)
  with
  | Oracle -> false
  | Skip | Rtl_h _ -> true
;;

let agree_prog t (instrs, regs, (flags, h, stall_seed), data) =
  let prog = Array.of_list (List.map prog_instr instrs) in
  let regs = Array.of_list regs in
  regs.(data_reg) <- data_base;
  (* eight seeded words around the data base; the rest of the region starts at zero *)
  let seeded = List.mapi (fun k w -> (data_base lsr 2) - 4 + k, w) data in
  (* ── the oracle ── *)
  let oram = R.For_tests.ram t.oracle in
  Array.fill oram data_lo (data_hi - data_lo) 0;
  List.iter (fun (w, v) -> oram.(w) <- v) seeded;
  Array.fill oram base_pc (prog_len + pad + 1) 0;
  Array.blit prog 0 oram base_pc prog_len;
  Array.blit regs 0 (R.For_tests.regs t.oracle) 0 16;
  R.For_tests.set_flags t.oracle flags;
  R.For_tests.set_h t.oracle h;
  R.For_tests.set_pc t.oracle base_pc;
  let steps = ref 0
  and executed = ref 0 (* program instructions, the trailing padding not counted *)
  and loads = ref 0
  and stores = ref 0
  and taken = ref 0
  and multi = ref 0
  and multi_pairs = ref 0
  and prev_multi = ref false in
  while R.For_tests.pc t.oracle <> end_pc do
    if !steps > prog_len + pad || oracle_next_is_steered t
    then (
      stats.discarded <- stats.discarded + 1;
      QCheck.assume_fail ());
    let pc = R.For_tests.pc t.oracle in
    let instr = oram.(pc) in
    R.For_tests.single_step t.oracle;
    incr steps;
    if pc < base_pc + prog_len
    then (
      incr executed;
      let is_multi = instr lsr 31 = 0 && (instr lsr 16) land 0xF >= 10 in
      (match instr lsr 30 with
       | 2 -> if (instr lsr 29) land 1 = 1 then incr stores else incr loads
       | 3 -> if R.For_tests.pc t.oracle <> pc + 1 then incr taken
       | _ -> if is_multi then incr multi);
      if is_multi && !prev_multi then incr multi_pairs;
      prev_multi := is_multi)
  done;
  (* ── the core, its bus served from [mem] ── *)
  let mem = Hashtbl.create 64 in
  let read w = Option.value (Hashtbl.find_opt mem w) ~default:0 in
  List.iter (fun (w, v) -> Hashtbl.replace mem w v) seeded;
  Array.iteri (fun k w -> Hashtbl.replace mem (base_pc + k) w) prog;
  let inp = Cyclesim.inputs t.sim in
  let set r v = r := Bits.of_unsigned_int ~width:(Bits.width !r) v in
  poke_core t (case_of ~regs ~op:0 ~instr:prog.(0) ~flags ~h);
  let lcg = ref stall_seed in
  let bus_ok = ref true in
  let cycles = ref 0 in
  while Cyclesim.Reg.to_int t.reg_pc <> end_pc && !cycles < 2_000 do
    lcg := ((!lcg * 1103515245) + 12345) land 0x7FFF_FFFF;
    (* One instruction class is not stall-transparent in RISC5.v, and the port follows it:
       C and OV are clocked from the adder on EVERY cycle an ADD/SUB sits in IR, stalled
       or not (RISC5.v:161-175 — only N/Z wait for [regwr]). Harmless for plain ADD/SUB,
       but ADD'/SUB' take C as carry-in, so a stalled cycle feeds the instruction its own
       carry-out. The oracle executes each instruction once, so those cycles are never
       stalled here (the formal core proof is what holds the port to the RTL there). *)
    let ir = Cyclesim.Reg.to_int t.reg_ir in
    let carry_in_op =
      ir lsr 31 = 0
      && (ir lsr 29) land 1 = 1
      &&
      let op = (ir lsr 16) land 0xF in
      op = 8 || op = 9
    in
    let stalled = (not carry_in_op) && (!lcg lsr 16) land 3 = 0 in
    set inp.stall_x (if stalled then 1 else 0);
    Cyclesim.cycle_before_clock_edge t.sim;
    let adr, rd, wr, ben = bus_pre t in
    if stalled
    then (
      (* the bus is someone else's this cycle: the core must not strobe, and must not
         consume what happens to be on it *)
      if rd = 1 || wr = 1 then bus_ok := false;
      set inp.codebus 0xDEAD_BEEF;
      t.inbus := Bits.of_unsigned_int ~width:32 0xDEAD_BEEF)
    else (
      let w = adr lsr 2 in
      if wr = 1
      then (
        let out = Bits.to_int_trunc !(t.out_pre.outbus) in
        let lane_mask = 0xFF lsl (8 * (adr land 3)) in
        Hashtbl.replace
          mem
          w
          (if ben = 1 then read w land lnot lane_mask lor (out land lane_mask) else out));
      set inp.codebus (read w);
      t.inbus := Bits.of_unsigned_int ~width:32 (read w));
    Cyclesim.cycle t.sim;
    incr cycles;
    if stalled then stats.stalled <- stats.stalled + 1
  done;
  stats.compared <- stats.compared + 1;
  stats.instrs <- stats.instrs + !executed;
  stats.loads <- stats.loads + !loads;
  stats.stores <- stats.stores + !stores;
  stats.taken <- stats.taken + !taken;
  stats.multi <- stats.multi + !multi;
  stats.multi_pairs <- stats.multi_pairs + !multi_pairs;
  stats.cycles <- stats.cycles + !cycles;
  set inp.stall_x 0;
  set inp.codebus 0;
  let ((hw_regs, hw_flags, hw_pc, hw_h) as hw) = read_core t in
  let ((or_regs, or_flags, or_pc, or_h) as oracle) = read_oracle t in
  let data_ok = ref true in
  for w = data_lo to data_hi - 1 do
    if read w <> oram.(w)
    then (
      data_ok := false;
      Printf.printf "  mem[%x]: core %08x, oracle %08x\n" w (read w) oram.(w))
  done;
  let ok = !bus_ok && !data_ok && state_eq hw oracle in
  (* say what differs: the raw draw QCheck prints is not readable on its own *)
  if not ok
  then (
    Printf.printf
      "  after %d cycles / %d oracle steps: pc %x/%x flags %x/%x h %08x/%08x strobed \
       under stallX: %b\n"
      !cycles
      !steps
      hw_pc
      or_pc
      hw_flags
      or_flags
      hw_h
      or_h
      (not !bus_ok);
    Array.iteri
      (fun k v ->
        if v <> or_regs.(k)
        then Printf.printf "  R%d: core %08x, oracle %08x\n" k v or_regs.(k))
      hw_regs);
  ok
;;

let () =
  let run ~name ~count ?max_gen arb prop =
    Risc5.Test_gen.check_exn (QCheck.Test.make ~count ?max_gen ~name arb prop);
    Printf.printf "cpu lockstep (%s): %d QCheck cases, passed\n%!" name count
  in
  let t = create () in
  (* corner-heavy operands; [max_gen] above [count] absorbs the discarded cases *)
  run ~name:"register ops 0..15" ~count:50_000 ~max_gen:60_000 seed (fun raw ->
    agree_reg_op t (decode raw));
  (* branches: nothing is written except a taken link, and PC takes the target. The one
     known corner, a branch-and-link through R15, is discarded. *)
  run ~name:"branches" ~count:50_000 ~max_gen:55_000 seed_branch (fun raw ->
    let case = decode_branch raw in
    QCheck.assume (not (steered_branch case));
    agree t case);
  (* loads: R[a] gets the byte-lane-selected / whole word from memory *)
  run ~name:"loads" ~count:50_000 seed_load (fun ((_, adr_byte, _, _, _) as raw) ->
    let case, byte_mode, load_val = decode_load raw in
    agree_load t ~case ~adr_byte ~byte_mode ~load_val);
  (* stores: memory at adr gets A (word) or A[7:0] in the addressed lane (byte) *)
  run ~name:"stores" ~count:50_000 seed_store (fun ((_, adr_byte, _, _, _) as raw) ->
    let case, init_word, byte_mode = decode_store raw in
    agree_store t ~case ~adr_byte ~init_word ~byte_mode);
  reset_stats ();
  run
    ~name:"programs, random stallX"
    ~count:20_000
    ~max_gen:40_000
    seed_prog
    (agree_prog t);
  print_stats ();
  (* The 2-stage pipelined DSP multipliers (the shipped board's choice of
     [Cpu.multipliers]) under the real core's driving: the register-op property, then the
     program property — where a multiply can directly follow a multiply, which no single-
     instruction case and neither unit differential ever does. The units are bit-identical
     to the faithful ones, so the same exceptions apply. *)
  let t_fast =
    create ~core:(fun i -> Core.create ~multipliers:(Dsp { stages = 2 }) i) ()
  in
  run
    ~name:"register ops, DSP multipliers, 2 stages"
    ~count:50_000
    ~max_gen:60_000
    seed
    (fun raw -> agree_reg_op t_fast (decode raw));
  reset_stats ();
  run
    ~name:"programs, random stallX, DSP multipliers, 2 stages"
    ~count:20_000
    ~max_gen:40_000
    seed_prog
    (agree_prog t_fast);
  print_stats ()
;;

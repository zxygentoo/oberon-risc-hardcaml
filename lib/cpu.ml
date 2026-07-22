(* Public API and behaviour spec live in [cpu.mli].

   Implementation note. This is the CPU core — the port of Wirth's RISC5.v, the module
   AGENT.md §2 calls the crown jewel. The whole processor is a handful of registers
   updated in a single clocked block (the [Always.compile] near the end of [create]),
   wrapped in a cloud of combinational logic that computes their next values. Per §2 we
   port the *behaviour*, not the surface syntax: we mirror the sequential skeleton exactly
   — which signals are registered, the stall and interrupt timing — because that is what
   the oracle checks and synthesis preserves; the combinational web around it is idiomatic
   Hardcaml.

   [create] reads top-to-bottom as the loop — decode -> fetch operands -> execute ->
   memory -> control -> writeback -> commit — with the [decode]/[execute]/[memory] stages
   factored out above it.

   Verification note: the OCaml oracle is interrupt-free, so the interrupt FSM has no
   lockstep counterpart — it is checked by a co-located behavioural waveform against the
   RISC5.v spec and (exhaustively) by the Phase-8 RTL co-sim; the instruction lockstep
   steers RTI/STI/CLI out (§8). *)

open Hardcaml
open Signal

module I = struct
  type 'a t =
    { clock : 'a
    ; rst_n : 'a [@bits 1] (* reset, active LOW; [_n] suffix: see .mli *)
    ; irq : 'a [@bits 1] (* interrupt request *)
    ; stall_x : 'a [@bits 1] (* external video-DMA stall *)
    ; inbus : 'a [@bits 32] (* data read bus *)
    ; codebus : 'a [@bits 32] (* instruction fetch bus = Mem[adr] *)
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { adr : 'a [@bits 24] (* byte address: fetch, or load/store data *)
    ; rd : 'a [@bits 1]
    ; wr : 'a [@bits 1]
    ; ben : 'a [@bits 1] (* byte enable *)
    ; outbus : 'a [@bits 32] (* data write bus — store data *)
    ; mem_pend : 'a [@bits 1]
    (* board seam: core needs the bus this cycle (fetch / data) — see [create_with_units] *)
    }
  [@@deriving hardcaml]
end

(* The decoded instruction: every signal derived purely from the IR word — the mode bits
   p/q/u/v, the register-op fields, the branch (cc/neg/disp) and load/store (off) fields,
   and the op-classes (ldr/str/br, the rti/sti_cli interrupt instructions, mul..fdv
   multi-cycle ops). Bundled so [create]'s datapath isn't fronted by 30 lines of
   bit-slicing. *)
type decoded =
  { p : Signal.t
  ; q : Signal.t
  ; u : Signal.t
  ; v : Signal.t
  ; ira : Signal.t
  ; irb : Signal.t
  ; op : Signal.t
  ; irc : Signal.t
  ; imm : Signal.t
  ; cc : Signal.t
  ; neg : Signal.t
  ; disp : Signal.t
  ; off : Signal.t (* 20-bit signed load/store offset *)
  ; ldr : Signal.t
  ; str : Signal.t
  ; br : Signal.t
  ; rti : Signal.t (* BR & ~u & ~v & IR[4] — return from interrupt *)
  ; sti_cli : Signal.t (* BR & ~u & ~v & IR[5] — writes intEnb := IR[0] *)
  ; mul : Signal.t
  ; div : Signal.t
  ; fad : Signal.t
  ; fsb : Signal.t
  ; fml : Signal.t
  ; fdv : Signal.t (* op = 10..15, the multi-cycle op-classes *)
  }

let decode ir : decoded =
  let p = bit ir ~pos:31 in
  let q = bit ir ~pos:30 in
  let u = bit ir ~pos:29 in
  let v = bit ir ~pos:28 in
  let op = select ir ~high:19 ~low:16 in
  let br = p &: q in
  let is_op k = ~:p &: (op ==:. k) in
  { p
  ; q
  ; u
  ; v
  ; ira = select ir ~high:27 ~low:24
  ; irb = select ir ~high:23 ~low:20
  ; op
  ; irc = select ir ~high:3 ~low:0
  ; imm = select ir ~high:15 ~low:0
  ; cc = select ir ~high:26 ~low:24
  ; neg = bit ir ~pos:27
  ; disp = select ir ~high:21 ~low:0
  ; off = select ir ~high:19 ~low:0
  ; ldr = p &: ~:q &: ~:u
  ; str = p &: ~:q &: u
  ; br
  ; rti = br &: ~:u &: ~:v &: bit ir ~pos:4
  ; sti_cli = br &: ~:u &: ~:v &: bit ir ~pos:5
  ; mul = is_op 10
  ; div = is_op 11
  ; fad = is_op 12
  ; fsb = is_op 13
  ; fml = is_op 14
  ; fdv = is_op 15
  }
;;

(* The eight submodule constructors, made injectable so the Phase-8 in-situ core proof
   (test/formal) can swap the real units for black-box Instantiation stubs and prove
   the *glue* (decode, the inline ALU, control, flags, the 13 state registers) with the
   units assumed-equivalent — sound because each is proven separately (§6). These are
   exactly the modules RISC5.v instantiates (the ALU's [aluRes] is inline there, so it
   stays inline here too — and gets proven as part of the glue). [create] uses
   [Units.with_ce] (= [Units.default] at the default [ce = vdd], the real units inlined),
   so sim / lockstep / boot are byte-for-byte unchanged. *)
module Units = struct
  type t =
    { left_shifter : Signal.t Left_shifter.I.t -> Signal.t Left_shifter.O.t
    ; right_shifter : Signal.t Right_shifter.I.t -> Signal.t Right_shifter.O.t
    ; multiplier : Signal.t Multiplier.I.t -> Signal.t Multiplier.O.t
    ; divider : Signal.t Divider.I.t -> Signal.t Divider.O.t
    ; fp_adder : Signal.t Fp_adder.I.t -> Signal.t Fp_adder.O.t
    ; fp_multiplier : Signal.t Fp_multiplier.I.t -> Signal.t Fp_multiplier.O.t
    ; fp_divider : Signal.t Fp_divider.I.t -> Signal.t Fp_divider.O.t
    ; registers : Signal.t Registers.I.t -> Signal.t Registers.O.t
    }

  (* Phase 7: [with_ce ce] binds the board clock-enable into the five iterative units, so
     they freeze with the ce-gated core during a PSRAM wait. The shifters are
     combinational and the register file's write is ce-gated in the glue, so neither takes
     [ce]. [default] is the [ce = vdd] case — [~enable:vdd] no-ops, so it is
     byte-identical to the bare units. *)
  let with_ce ce =
    { left_shifter = Left_shifter.create
    ; right_shifter = Right_shifter.create
    ; multiplier = Multiplier.create ~ce
    ; divider = Divider.create ~ce
    ; fp_adder = Fp_adder.create ~ce
    ; fp_multiplier = Fp_multiplier.create ~ce
    ; fp_divider = Fp_divider.create ~ce
    ; registers = Registers.create
    }
  ;;

  let default = with_ce vdd
end

(* [execute]'s results (unique field names — Hardcaml interfaces collide on
   [res]/[stall]/…, and warning 42 is an error here): the selected datapath result, the
   ALU's add/sub carry/overflow (for C/OV), the MUL high word and DIV remainder (for H),
   and the OR of the five iterative units' stalls. *)
type execute_out =
  { result : Signal.t
  ; alu_c : Signal.t
  ; alu_ov : Signal.t
  ; product_hi : Signal.t
  ; remainder : Signal.t
  ; unit_stall : Signal.t
  }

(* Execute: B/C1 fan out to the combinational shifters and the ALU (MOV/logic/ADD-SUB),
   and B/C1/C0 to the five iterative units (MUL/DIV/FP); [op] selects one result. MUL/DIV
   take the *inverted* u-bit ([~u]: signed is u=1); the FP units are register-register
   (operand 2 is C0), and FSB reuses the adder with operand 2's sign bit flipped. Each
   iterative unit asserts stall until its counter ends. The current flags N/Z/C/OV feed
   the ALU (the add/sub carry-in and the MOV' flags read). *)
let execute ~(units : Units.t) ~clock ~(dec : decoded) ~b ~c1 ~c0 ~shamt ~h ~n ~z ~c ~ov
  : execute_out
  =
  let lsh = units.left_shifter { Left_shifter.I.x = b; sc = shamt } in
  let rsh = units.right_shifter { Right_shifter.I.x = b; sc = shamt; md = lsb dec.op } in
  let alu =
    Alu.create
      { Alu.I.p = dec.p
      ; op = dec.op
      ; u = dec.u
      ; q = dec.q
      ; v = dec.v
      ; imm = dec.imm
      ; b
      ; c1
      ; h
      ; n_in = n
      ; z_in = z
      ; c_in = c
      ; ov_in = ov
      }
  in
  let mul =
    units.multiplier { Multiplier.I.clock; run = dec.mul; u = ~:(dec.u); x = b; y = c1 }
  in
  let div =
    units.divider { Divider.I.clock; run = dec.div; u = ~:(dec.u); x = b; y = c1 }
  in
  let fpa =
    units.fp_adder
      { Fp_adder.I.clock
      ; run = dec.fad |: dec.fsb
      ; u = dec.u
      ; v = dec.v
      ; x = b
      ; y = (dec.fsb ^: msb c0) @: select c0 ~high:30 ~low:0
      }
  in
  let fpm = units.fp_multiplier { Fp_multiplier.I.clock; run = dec.fml; x = b; y = c0 } in
  let fpd = units.fp_divider { Fp_divider.I.clock; run = dec.fdv; x = b; y = c0 } in
  let res =
    mux
      dec.op
      [ alu.res (* 0 MOV *)
      ; lsh.y (* 1 LSL *)
      ; rsh.y (* 2 ASR *)
      ; rsh.y (* 3 ROR *)
      ; alu.res (* 4 AND *)
      ; alu.res (* 5 ANN *)
      ; alu.res (* 6 IOR *)
      ; alu.res (* 7 XOR *)
      ; alu.res (* 8 ADD *)
      ; alu.res (* 9 SUB *)
      ; sel_bottom mul.z ~width:32 (* 10 MUL — product[31:0] *)
      ; div.quot (* 11 DIV *)
      ; fpa.z (* 12 FAD *)
      ; fpa.z (* 13 FSB *)
      ; fpm.z (* 14 FML *)
      ; fpd.z (* 15 FDV *)
      ]
  in
  { result = res
  ; alu_c = alu.c
  ; alu_ov = alu.ov
  ; product_hi = select mul.z ~high:63 ~low:32
  ; remainder = div.rem
  ; unit_stall = mul.stall |: div.stall |: fpa.stall |: fpm.stall |: fpd.stall
  }
;;

(* [memory]'s results (unique field names, as above): the load data, the data address (for
   the bus [adr]), the rd/wr/ben strobes, the first load/store stall cycle, and store
   data. *)
type memory_out =
  { load_data : Signal.t
  ; data_adr : Signal.t
  ; read : Signal.t
  ; write : Signal.t
  ; byte_en : Signal.t
  ; stall_l0 : Signal.t
  ; store_data : Signal.t
  }

(* Memory access: the data address B+sign-extend(off), the byte enable, the load byte-lane
   select (a byte load picks the lane at adr[1:0] and zero-extends; a word load passes
   inbus through), the store byte replicate, and the rd/wr strobes. [stall_l0] is the
   first of the two load/store stall cycles. *)
let memory ~(dec : decoded) ~a ~b ~inbus ~stall_x ~stall_l1 : memory_out =
  (* (LDR|STR) & ~stallL1 (RISC5.v:168) — the OR bound first by name: &:/|: are
     equal-precedence left-assoc, so the bare mix parses right but READS wrong under
     Verilog/C intuition (ocamlformat strips clarifying parens as redundant) *)
  let ld_or_st = dec.ldr |: dec.str in
  let stall_l0 = ld_or_st &: ~:stall_l1 in
  let not_stalled = ~:stall_x &: ~:stall_l1 in
  let data_adr = sel_bottom b ~width:24 +: sresize dec.off ~width:24 in
  let ben = ld_or_st &: dec.v &: not_stalled in
  let byte_lane = sel_bottom data_adr ~width:2 in
  (* byte load: pick the addressed lane (zero-extended below); byte store: lift a's low
     byte into that lane, zeros elsewhere *)
  let load_byte = mux byte_lane (split_lsb inbus ~part_width:8) in
  let inbus1 = mux2 ben (zero 24 @: load_byte) inbus in
  let a8 = sel_bottom a ~width:8 in
  let store_byte =
    mux byte_lane (List.init 4 (fun lane -> sll (uresize a8 ~width:32) ~by:(8 * lane)))
  in
  let outbus = mux2 ben store_byte a in
  let rd = dec.ldr &: not_stalled in
  let wr = dec.str &: not_stalled in
  { load_data = inbus1
  ; data_adr
  ; read = rd
  ; write = wr
  ; byte_en = ben
  ; stall_l0
  ; store_data = outbus
  }
;;

(* the reset vector ([RISC5.v]'s [StartAdr]), a word address. Exported so the SoC's ROM
   window derives from the same constant (its adr[23:14] tag = [start_adr lsr 12]) instead
   of a second copy. *)
let start_adr = 0x3F_F800

let create_with_units ?(ce = vdd) ~(units : Units.t) (i : _ I.t) : _ O.t =
  let spec = Reg_spec.create () ~clock:i.clock in
  (* ── State registers ── the loop's carried state: PC, IR, the stallL1 flop, the
     condition flags N/Z/C/OV, the aux register H (MUL high word / DIV remainder), and the
     interrupt state. Faithful no-reset registers (no clear port); [rst_n] (active low)
     reaches the datapath as ordinary logic (the [pcmux] below), as the RTL does it.
     [pc]/[ir]/[stall]/[regmux], the flags and [h] are named (--) so the waveform and
     lockstep tests can watch and poke them. *)
  let pc = Always.Variable.reg spec ~enable:ce ~width:22 in
  let ir = Always.Variable.reg spec ~enable:ce ~width:32 in
  let stall_l1 = Always.Variable.reg spec ~enable:ce ~width:1 in
  let n = Always.Variable.reg spec ~enable:ce ~width:1 in
  let z = Always.Variable.reg spec ~enable:ce ~width:1 in
  let c = Always.Variable.reg spec ~enable:ce ~width:1 in
  let ov = Always.Variable.reg spec ~enable:ce ~width:1 in
  let h = Always.Variable.reg spec ~enable:ce ~width:32 in
  (* The interrupt state: the IRQ edge-detect flop, the enable / pending / in-handler
     flags, and SPC = [{saved flags, saved PC}] (4 + 22 = 26 bits). *)
  let irq1 = Always.Variable.reg spec ~enable:ce ~width:1 in
  let int_enb = Always.Variable.reg spec ~enable:ce ~width:1 in
  let int_pnd = Always.Variable.reg spec ~enable:ce ~width:1 in
  let int_md = Always.Variable.reg spec ~enable:ce ~width:1 in
  let spc = Always.Variable.reg spec ~enable:ce ~width:26 in
  let pc_v = pc.value -- "pc" in
  let ir_v = ir.value -- "ir" in
  let stall_l1_v = stall_l1.value -- "stall_l1" in
  let n_v = n.value -- "n" in
  let z_v = z.value -- "z" in
  let c_v = c.value -- "c" in
  let ov_v = ov.value -- "ov" in
  let h_v = h.value -- "h" in
  let irq1_v = irq1.value -- "irq1" in
  let int_enb_v = int_enb.value -- "int_enb" in
  let int_pnd_v = int_pnd.value -- "int_pnd" in
  let int_md_v = int_md.value -- "int_md" in
  let spc_v = spc.value -- "spc" in
  (* ── Decode ── slice the IR word into its fields; see [decode] above. *)
  let dec = decode ir_v in
  (* ── Fetch operands ── the register file's three async reads A/B/C0 (A is the store
     data); the write port commits [regmux] to R[ira0] at the edge. That
     read->compute->write is a loop the sequential write breaks, so [din]/[wr] are forward
     [wire]s, assigned once [regmux]/[regwr] exist below. C1 is operand 2 (the v-extended
     immediate, or C0). *)
  let ira0 = mux2 dec.br (of_unsigned_int ~width:4 15) dec.ira in
  (* a branch links PC+1 to R15 *)
  let regmux_w = wire 32 in
  let regwr_w = wire 1 in
  let regs =
    units.registers
      { Registers.I.clock = i.clock
      ; wr = regwr_w
      ; rno0 = ira0
      ; rno1 = dec.irb
      ; rno2 = dec.irc
      ; din = regmux_w
      }
  in
  let a = regs.dout0 in
  let b = regs.dout1 in
  let c0 = regs.dout2 in
  let c1 = mux2 dec.q (repeat dec.v ~count:16 @: dec.imm) c0 in
  let shamt = sel_bottom c1 ~width:5 in
  (* ── Execute ── run B/C1/C0 through the shifters, ALU and the five iterative units;
     [op] picks the result. See [execute] above. *)
  let exe =
    execute
      ~units
      ~clock:i.clock
      ~dec
      ~b
      ~c1
      ~c0
      ~shamt
      ~h:h_v
      ~n:n_v
      ~z:z_v
      ~c:c_v
      ~ov:ov_v
  in
  (* ── Memory access ── data address, byte-lane load select, byte store replicate, and
     the rd/wr/ben strobes. See [memory] above. *)
  let mem = memory ~dec ~a ~b ~inbus:i.inbus ~stall_x:i.stall_x ~stall_l1:stall_l1_v in
  (* ── Control ── [stall] freezes the loop (load/store + external + the iterative units);
     [cond]/[pcmux0] are the branch (the §7 cc table, negated by IR[27]; a taken branch
     targets PC+1+disp or R.c>>2); [int_ack] fires for an enabled, pending interrupt when
     not already in a handler and not stalling. *)
  let stall = (mem.stall_l0 |: i.stall_x |: exe.unit_stall) -- "stall" in
  let int_ack = int_pnd_v &: int_enb_v &: ~:int_md_v &: ~:stall in
  let nxpc = pc_v +:. 1 in
  let s = n_v ^: ov_v in
  let cond =
    dec.neg
    ^: mux
         dec.cc
         [ n_v (* 0 MI/PL *)
         ; z_v (* 1 EQ/NE *)
         ; c_v (* 2 CS/CC *)
         ; ov_v (* 3 VS/VC *)
         ; c_v |: z_v (* 4 LS/HI *)
         ; s (* 5 LT/GE *)
         ; s |: z_v (* 6 LE/GT *)
         ; vdd (* 7 T/F *)
         ]
  in
  let pcmux0 =
    mux2 (dec.br &: cond) (mux2 dec.u (nxpc +: dec.disp) (select c0 ~high:23 ~low:2)) nxpc
  in
  (* ── Writeback ── [regmux] writes a load's data, a linking branch's return address,
     else the result; [regwr] is its enable; the flags take their next values (but RTI
     restores all four from SPC); H takes the MUL high word / DIV remainder. *)
  let link = zero 8 @: nxpc @: zero 2 in
  (* the return byte address {PC+1, 2'b0} *)
  let regmux =
    mux2 dec.ldr mem.load_data (mux2 (dec.br &: dec.v) link exe.result) -- "regmux"
  in
  assign regmux_w regmux;
  let regwr =
    ~:(dec.p)
    &: ~:stall
    |: (dec.br &: cond &: dec.v &: ~:(i.stall_x))
    |: (dec.ldr &: ~:(i.stall_x) &: ~:stall_l1_v)
  in
  (* fires for a register op (not stalled), a taken linking branch, or a load — and only
     when [ce] is high, so a memory wait can't let the write commit (the board freeze). *)
  assign regwr_w (regwr &: ce);
  (* N/Z from the written value, C/OV from the ALU — except RTI restores all four from SPC *)
  let nn = mux2 dec.rti (bit spc_v ~pos:25) (mux2 regwr (msb regmux) n_v) in
  let zz = mux2 dec.rti (bit spc_v ~pos:24) (mux2 regwr (regmux ==:. 0) z_v) in
  let cx = mux2 dec.rti (bit spc_v ~pos:23) exe.alu_c in
  let vv = mux2 dec.rti (bit spc_v ~pos:22) exe.alu_ov in
  let h_next = mux2 dec.mul exe.product_hi (mux2 dec.div exe.remainder h_v) in
  (* ── Interrupt next-state ── on intAck, SPC latches [{flags, return PC}]; intPnd sets
     on a rising IRQ edge and clears on intAck; intMd marks "in handler" (set on intAck,
     cleared by RTI); intEnb is reset-cleared and written by STI/CLI (its enable bit is
     IR[0]). *)
  let spc_next = mux2 int_ack (nn @: zz @: cx @: vv @: pcmux0) spc_v in
  let int_pnd_next = i.rst_n &: ~:int_ack &: (~:irq1_v &: i.irq |: int_pnd_v) in
  let int_md_next = i.rst_n &: ~:(dec.rti) &: (int_ack |: int_md_v) in
  let int_enb_next = mux2 ~:(i.rst_n) (zero 1) (mux2 dec.sti_cli (lsb ir_v) int_enb_v) in
  (* ── Next PC ── priority reset > stall > intAck (the interrupt vector, address 1) > RTI
     (restore SPC[21:0]) > branch/step; intAck is [~stall]-gated so it never collides with
     the stall term above it. *)
  let start_pc = of_unsigned_int ~width:22 start_adr in
  (* the reset vector, StartAdr *)
  let spc_pc = select spc_v ~high:21 ~low:0 in
  (* the return PC lives in SPC[21:0] *)
  let pcmux =
    mux2
      ~:(i.rst_n)
      start_pc
      (mux2
         stall
         pc_v
         (mux2 int_ack (of_unsigned_int ~width:22 1) (mux2 dec.rti spc_pc pcmux0)))
  in
  (* ── Commit ── the one clocked update: PC/IR/stallL1 + flags + H + the interrupt state,
     all latched at the edge (and frozen by [stall]). *)
  Always.(
    compile
      [ pc <-- pcmux
      ; ir <-- mux2 stall ir_v i.codebus
      ; stall_l1 <-- mux2 i.stall_x stall_l1_v mem.stall_l0
      ; n <-- nn
      ; z <-- zz
      ; c <-- cx
      ; ov <-- vv
      ; h <-- h_next
      ; irq1 <-- i.irq
      ; int_pnd <-- int_pnd_next
      ; int_md <-- int_md_next
      ; int_enb <-- int_enb_next
      ; spc <-- spc_next
      ]);
  (* ── Memory bus out ── [adr] is the data address while stalling for a load/store, else
     the fetch address. *)
  let adr = mux2 mem.stall_l0 mem.data_adr (pcmux @: zero 2) in
  (* [mem_pend]: the core drives a real bus access this cycle — a fetch ([~stall]) or a
     load/store data access ([stall_l0]); low ⟺ a pure compute stall (an iterative unit
     grinding, needing no memory). The board's PSRAM arbiter reads it to time its accesses
     and hold [ce] low until the word is ready (the sim SoC ignores it). *)
  let mem_pend = mem.stall_l0 |: ~:stall in
  { O.adr
  ; rd = mem.read
  ; wr = mem.write
  ; ben = mem.byte_en
  ; outbus = mem.store_data
  ; mem_pend
  }
;;

(* The synthesizable core: the real units, inlined exactly as before. [?ce] (default
   [vdd]) is the board clock-enable — driven low it freezes every state register, the
   register-file write and all five iterative units together for a multi-cycle PSRAM wait,
   so the slow memory looks single-cycle to the core (AGENT.md §3). [vdd] ⇒ byte-identical
   to the bare RTL port. *)
let create ?(ce = vdd) ?(fast_mul = false) ?(mul_stages = 0) i =
  (* [fast_mul] (Phase 9, AGENT.md §5) swaps the two iterative shift-add multipliers — the
     integer [Multiplier] (33 cycles) and the FP [Fp_multiplier] mantissa engine (25) —
     for their DSP variants (each proven bit-identical) through the units seam. Everything
     else, and the default [create], stays the faithful port.

     [mul_stages] (experiment feat/fast-clock) picks the DSP variant: [0] (default) = the
     combinational [create_opt] (the 50 MHz build); [>0] = [create_opt_pipelined] with
     that many pipeline registers on the product, which Vivado retimes into the DSP48 so
     the multiply leaves the critical path — for pushing the clock past ~52 MHz. *)
  let units = Units.with_ce ce in
  let units =
    if fast_mul
    then
      { units with
        multiplier =
          (if mul_stages = 0
           then Multiplier.create_opt ~ce
           else Multiplier.create_opt_pipelined ~ce ~stages:mul_stages)
      ; fp_multiplier =
          (if mul_stages = 0
           then Fp_multiplier.create_opt ~ce
           else Fp_multiplier.create_opt_pipelined ~ce ~stages:mul_stages)
      }
    else units
  in
  create_with_units ~ce ~units i
;;

(* ── Tests (co-located; AGENT.md §6) ── behaviour waveforms; the architectural lockstep
   against the oracle lives in test/. First the fetch/stall spine: reset loads StartAdr,
   PC marches through fetched instructions, a load asserts a one-cycle stall (PC/IR
   freeze, rd pulses, the 2-cycle access), and the external stall_x freezes the core the
   same way. The internal pc/ir/stall are traced (Cyclesim.Config.trace_all + the (--)
   names above). *)

(* shared by the waveform tests below: the input poke and the fail-loud lookup unwrap *)
let set r v w = r := Bits.of_unsigned_int ~width:w v

let some = function
  | Some x -> x
  | None -> failwith "lookup"
;;

let%expect_test "fetch spine — reset, PC march, load stall, external stall [waveform]" =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let module Waveform = Hardcaml_waveterm.Waveform in
  let module D = Hardcaml_waveterm.Display_rule in
  let sim = Sim.create ~config:Cyclesim.Config.trace_all create in
  let waves, sim = Cyclesim.Waveform.create sim in
  let inp = Cyclesim.inputs sim in
  let step ~rst_n ~stall_x ~codebus =
    set inp.rst_n rst_n 1;
    set inp.stall_x stall_x 1;
    set inp.codebus codebus 32;
    Cyclesim.cycle sim
  in
  (* one reset cycle (rst_n=0), then fetch register ops (p=0, no stall); a LDR
     (p=1,q=0,u=0 -> 0x8000_0000) shows the 2-cycle access — stall+rd for a cycle while
     PC/IR freeze — and a stall_x pulse shows the external freeze. The codebus payloads
     are arbitrary: this waveform watches only the fetch/stall spine, not the datapath
     result. (In the real machine codebus = Mem[adr], so the frozen adr re-fetches the
     same word during a stall; here it is free-driven, so the stalled payloads are not
     latched.) *)
  step ~rst_n:0 ~stall_x:0 ~codebus:0x0000_0000;
  step ~rst_n:1 ~stall_x:0 ~codebus:0x1111_1111;
  step ~rst_n:1 ~stall_x:0 ~codebus:0x8000_0000;
  step ~rst_n:1 ~stall_x:0 ~codebus:0x2222_2222;
  step ~rst_n:1 ~stall_x:0 ~codebus:0x3333_3333;
  step ~rst_n:1 ~stall_x:1 ~codebus:0x4444_4444;
  step ~rst_n:1 ~stall_x:0 ~codebus:0x5555_5555;
  Waveform.print
    ~display_rules:
      D.
        [ port_name_is ~wave_format:Wave_format.Bit "rst_n"
        ; port_name_is ~wave_format:Wave_format.Bit "stall_x"
        ; port_name_is ~wave_format:Wave_format.Hex "codebus"
        ; port_name_is ~wave_format:Wave_format.Hex "pc"
        ; port_name_is ~wave_format:Wave_format.Hex "ir"
        ; port_name_is ~wave_format:Wave_format.Bit "stall"
        ; port_name_is ~wave_format:Wave_format.Bit "rd"
        ; port_name_is ~wave_format:Wave_format.Hex "adr"
        ]
    ~wave_width:4
    ~display_width:93
    waves;
  [%expect
    {|
    ┌Signals───────────┐┌Waves──────────────────────────────────────────────────────────────────┐
    │rst_n             ││          ┌─────────────────────────────────────────────────────────── │
    │                  ││──────────┘                                                            │
    │stall_x           ││                                                  ┌─────────┐          │
    │                  ││──────────────────────────────────────────────────┘         └───────── │
    │                  ││──────────┬─────────┬─────────┬─────────┬─────────┬─────────┬───────── │
    │codebus           ││ 00000000 │11111111 │80000000 │22222222 │33333333 │44444444 │55555555  │
    │                  ││──────────┴─────────┴─────────┴─────────┴─────────┴─────────┴───────── │
    │                  ││──────────┬─────────┬─────────┬───────────────────┬─────────────────── │
    │pc                ││ 000000   │3FF800   │3FF801   │3FF802             │3FF803              │
    │                  ││──────────┴─────────┴─────────┴───────────────────┴─────────────────── │
    │                  ││────────────────────┬─────────┬───────────────────┬─────────────────── │
    │ir                ││ 00000000           │11111111 │80000000           │33333333            │
    │                  ││────────────────────┴─────────┴───────────────────┴─────────────────── │
    │stall             ││                              ┌─────────┐         ┌─────────┐          │
    │                  ││──────────────────────────────┘         └─────────┘         └───────── │
    │rd                ││                              ┌─────────┐                              │
    │                  ││──────────────────────────────┘         └───────────────────────────── │
    │                  ││──────────┬─────────┬─────────┬─────────┬───────────────────┬───────── │
    │adr               ││ FFE000   │FFE004   │FFE008   │000000   │FFE00C             │FFE010    │
    │                  ││──────────┴─────────┴─────────┴─────────┴───────────────────┴───────── │
    └──────────────────┘└───────────────────────────────────────────────────────────────────────┘
    |}]
;;

(* The register-op datapath computes and writes back. Not lockstep (that is the oracle's
   job, test/), but a visible check that MOV/ADD/SUB flow through the register file,
   result mux, and flags. A tiny straight-line program, each instruction fed on codebus
   and executing the next cycle (no stalls), reading back what the prior ones wrote (async
   read / sync write, no hazard). regmux is the writeback value; the flags
   are *registered*, so N/Z/C/OV land the cycle after the result they reflect. *)

let%expect_test "register ops — MOV/ADD/SUB compute, write back, set flags [waveform]" =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let module Waveform = Hardcaml_waveterm.Waveform in
  let module D = Hardcaml_waveterm.Display_rule in
  let sim = Sim.create ~config:Cyclesim.Config.trace_all create in
  let waves, sim = Cyclesim.Waveform.create sim in
  let inp = Cyclesim.inputs sim in
  let step ~rst_n ~codebus =
    set inp.rst_n rst_n 1;
    set inp.stall_x 0 1;
    set inp.codebus codebus 32;
    Cyclesim.cycle sim
  in
  (* MOV R1,#5 ; MOV R2,#3 ; ADD R3,R1,R2 (=8) ; SUB R4,R2,R1 (=-2). The SUB's negative
     result sets N=1, and its borrow sets C=1 (which then holds, since only ADD/SUB touch
     C/OV); the two trailing NOPs let those registered flags become visible. *)
  step ~rst_n:0 ~codebus:0x0000_0000;
  step ~rst_n:1 ~codebus:0x4100_0005;
  step ~rst_n:1 ~codebus:0x4200_0003;
  step ~rst_n:1 ~codebus:0x0318_0002;
  step ~rst_n:1 ~codebus:0x0429_0001;
  step ~rst_n:1 ~codebus:0x0000_0000;
  step ~rst_n:1 ~codebus:0x0000_0000;
  Waveform.print
    ~display_rules:
      D.
        [ port_name_is ~wave_format:Wave_format.Hex "ir"
        ; port_name_is ~wave_format:Wave_format.Hex "regmux"
        ; port_name_is ~wave_format:Wave_format.Bit "n"
        ; port_name_is ~wave_format:Wave_format.Bit "z"
        ; port_name_is ~wave_format:Wave_format.Bit "c"
        ; port_name_is ~wave_format:Wave_format.Bit "ov"
        ]
    ~wave_width:4
    ~display_width:93
    waves;
  [%expect
    {|
    ┌Signals───────────┐┌Waves──────────────────────────────────────────────────────────────────┐
    │                  ││────────────────────┬─────────┬─────────┬─────────┬─────────┬───────── │
    │ir                ││ 00000000           │41000005 │42000003 │03180002 │04290001 │00000000  │
    │                  ││────────────────────┴─────────┴─────────┴─────────┴─────────┴───────── │
    │                  ││────────────────────┬─────────┬─────────┬─────────┬─────────┬───────── │
    │regmux            ││ 00000000           │00000005 │00000003 │00000008 │FFFFFFFE │00000000  │
    │                  ││────────────────────┴─────────┴─────────┴─────────┴─────────┴───────── │
    │n                 ││                                                            ┌───────── │
    │                  ││────────────────────────────────────────────────────────────┘          │
    │z                 ││          ┌───────────────────┐                                        │
    │                  ││──────────┘                   └─────────────────────────────────────── │
    │c                 ││                                                            ┌───────── │
    │                  ││────────────────────────────────────────────────────────────┘          │
    │ov                ││                                                                       │
    │                  ││────────────────────────────────────────────────────────────────────── │
    └──────────────────┘└───────────────────────────────────────────────────────────────────────┘
    |}]
;;

(* A multi-cycle op (MUL) freezes the whole core. We poke operands + a signed MUL R3,R1,R2
   (7*6=42) and run it to completion: the multiplier asserts [stall], which holds PC and
   IR frozen for 33 cycles (the unit's state counter running), then on the cycle [stall]
   drops the result mux's product[31:0] writes back (regmux) and product[63:32] lands
   in H. DIV/FP work identically through the same stall path. The product is too wide for
   a tight window, so we show the head (stall onset, PC/IR frozen) and the tail (stall
   drops, the writeback). *)

let%expect_test "MUL — the core stalls, PC/IR freeze, then product + H write back \
                 [waveform]"
  =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let module Waveform = Hardcaml_waveterm.Waveform in
  let module D = Hardcaml_waveterm.Display_rule in
  let sim = Sim.create ~config:Cyclesim.Config.trace_all create in
  let waves, sim = Cyclesim.Waveform.create sim in
  let inp = Cyclesim.inputs sim in
  let regfile = some (Cyclesim.lookup_mem_by_name sim "regfile") in
  let reg name = some (Cyclesim.lookup_reg_by_name sim name) in
  let stall = some (Cyclesim.lookup_node_by_name sim "stall") in
  inp.rst_n := Bits.of_unsigned_int ~width:1 1;
  inp.stall_x := Bits.of_unsigned_int ~width:1 0;
  inp.codebus := Bits.of_unsigned_int ~width:32 0;
  Cyclesim.Memory.of_int regfile ~address:1 7;
  Cyclesim.Memory.of_int regfile ~address:2 6;
  Cyclesim.Reg.of_int (reg "ir") 0x031A_0002 (* signed MUL R3,R1,R2 *);
  Cyclesim.Reg.of_int (reg "pc") 0x100;
  Cyclesim.cycle sim;
  while Cyclesim.Node.to_int stall = 1 do
    Cyclesim.cycle sim
  done;
  Cyclesim.cycle sim;
  let rules =
    D.
      [ port_name_is ~wave_format:Wave_format.Hex "ir"
      ; port_name_is ~wave_format:Wave_format.Hex "pc"
      ; port_name_is ~wave_format:Wave_format.Bit "stall"
      ; port_name_is ~wave_format:Wave_format.Hex "regmux"
      ; port_name_is ~wave_format:Wave_format.Hex "h"
      ]
  in
  (* head: IR latched with the MUL, stall asserts, PC frozen at 0x100 *)
  Waveform.print ~display_rules:rules ~start_cycle:0 ~wave_width:4 ~display_width:70 waves;
  [%expect
    {|
    ┌Signals────────┐┌Waves──────────────────────────────────────────────┐
    │               ││───────────────────────────────────────────────────│
    │ir             ││ 031A0002                                          │
    │               ││───────────────────────────────────────────────────│
    │               ││───────────────────────────────────────────────────│
    │pc             ││ 000100                                            │
    │               ││───────────────────────────────────────────────────│
    │stall          ││───────────────────────────────────────────────────│
    │               ││                                                   │
    │               ││──────────┬─────────┬─────────┬─────────┬─────────┬│
    │regmux         ││ 00000000 │00000007 │00000003 │80000001 │40000000 ││
    │               ││──────────┴─────────┴─────────┴─────────┴─────────┴│
    │               ││──────────────────────────────┬─────────┬─────────┬│
    │h              ││ 00000000                     │00000003 │00000004 ││
    │               ││──────────────────────────────┴─────────┴─────────┴│
    └───────────────┘└───────────────────────────────────────────────────┘
    |}];
  (* tail: stall drops, regmux = product[31:0] = 42 (0x2A), H = product[63:32] = 0, PC++ *)
  Waveform.print
    ~display_rules:rules
    ~start_cycle:31
    ~wave_width:4
    ~display_width:44
    waves;
  [%expect
    {|
    ┌Signals──┐┌Waves──────────────────────────┐
    │         ││────────────────────────────── │
    │ir       ││ 031A0002                      │
    │         ││────────────────────────────── │
    │         ││────────────────────────────── │
    │pc       ││ 000100                        │
    │         ││────────────────────────────── │
    │stall    ││────────────────────┐          │
    │         ││                    └───────── │
    │         ││──────────┬─────────┬───────── │
    │regmux   ││ 000000A8 │00000054 │0000002A  │
    │         ││──────────┴─────────┴───────── │
    │         ││────────────────────────────── │
    │h        ││ 00000000                      │
    │         ││────────────────────────────── │
    └─────────┘└───────────────────────────────┘
    |}]
;;

(* A branch changes PC instead of writing a register. We poke a taken relative
   branch-and-link (BL) and a not-taken conditional, each run two cycles so the PC
   register shows the post-branch value: the BL's regmux is the return byte-address
   [{PC+1,2'b0}] (the link, written to R15) and PC jumps to nxpc+disp; the not-taken
   branch's regmux is the unwritten ALU result and PC simply falls through to nxpc. *)

let%expect_test "branches — taken BL (jump + link) vs not-taken (fall-through) [waveform]"
  =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let module Waveform = Hardcaml_waveterm.Waveform in
  let module D = Hardcaml_waveterm.Display_rule in
  let sim = Sim.create ~config:Cyclesim.Config.trace_all create in
  let waves, sim = Cyclesim.Waveform.create sim in
  let inp = Cyclesim.inputs sim in
  let reg name = some (Cyclesim.lookup_reg_by_name sim name) in
  inp.rst_n := Bits.of_unsigned_int ~width:1 1;
  inp.stall_x := Bits.of_unsigned_int ~width:1 0;
  inp.codebus := Bits.of_unsigned_int ~width:32 0;
  let branch ~z ~instr =
    Cyclesim.Reg.of_int (reg "z") z;
    Cyclesim.Reg.of_int (reg "ir") instr;
    Cyclesim.Reg.of_int (reg "pc") 0x100;
    Cyclesim.cycle sim;
    Cyclesim.cycle sim
  in
  (* BL T relative disp=+3 (cc=7=T, v=1 link): pc 0x100 -> nxpc(0x101)+3 = 0x104, regmux =
     link = 0x101<<2 = 0x404. Then B EQ disp=8 with Z=0 (not taken): pc -> nxpc 0x101. *)
  branch ~z:0 ~instr:0xF700_0003;
  branch ~z:0 ~instr:0xE100_0008;
  Waveform.print
    ~display_rules:
      D.
        [ port_name_is ~wave_format:Wave_format.Hex "ir"
        ; port_name_is ~wave_format:Wave_format.Hex "pc"
        ; port_name_is ~wave_format:Wave_format.Hex "regmux"
        ]
    ~wave_width:4
    ~display_width:58
    waves;
  [%expect
    {|
    ┌Signals─────┐┌Waves─────────────────────────────────────┐
    │            ││──────────┬─────────┬─────────┬─────────  │
    │ir          ││ F7000003 │00000000 │E1000008 │00000000   │
    │            ││──────────┴─────────┴─────────┴─────────  │
    │            ││──────────┬─────────┬─────────┬─────────  │
    │pc          ││ 000100   │000104   │000100   │000101     │
    │            ││──────────┴─────────┴─────────┴─────────  │
    │            ││──────────┬─────────┬─────────┬─────────  │
    │regmux      ││ 00000404 │00000000 │00080000 │00000000   │
    │            ││──────────┴─────────┴─────────┴─────────  │
    └────────────┘└──────────────────────────────────────────┘
    |}]
;;

(* A load/store is a 2-cycle access: the stallL0 cycle drives the data address B+off and
   the rd/wr strobe (PC/IR frozen), then a bubble cycle. We poke a word load (R1 <- inbus,
   the byte-lane select gives the whole word) and a byte store (outbus = R1[7:0]
   replicated into the addressed lane). regmux is the load writeback; outbus the store
   data. *)

let%expect_test "load/store — 2-cycle access: data adr, rd/wr, byte lane [waveform]" =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let module Waveform = Hardcaml_waveterm.Waveform in
  let module D = Hardcaml_waveterm.Display_rule in
  let sim = Sim.create ~config:Cyclesim.Config.trace_all create in
  let waves, sim = Cyclesim.Waveform.create sim in
  let inp = Cyclesim.inputs sim in
  let mem = some (Cyclesim.lookup_mem_by_name sim "regfile") in
  let reg name = some (Cyclesim.lookup_reg_by_name sim name) in
  inp.rst_n := Bits.of_unsigned_int ~width:1 1;
  inp.stall_x := Bits.of_unsigned_int ~width:1 0;
  inp.codebus := Bits.of_unsigned_int ~width:32 0;
  let access ~r1 ~r2 ~inbus ~instr =
    Cyclesim.Memory.of_int mem ~address:1 r1;
    Cyclesim.Memory.of_int mem ~address:2 r2;
    inp.inbus := Bits.of_unsigned_int ~width:32 inbus;
    Cyclesim.Reg.of_int (reg "ir") instr;
    Cyclesim.Reg.of_int (reg "pc") 0x100;
    Cyclesim.cycle sim;
    Cyclesim.cycle sim
  in
  (* LDR word R1,[R2+0] (R2=0x1000, inbus=0xDEADBEEF); STR byte R1,[R2+2] (R1=0xAB,
     R2=0x2000 -> outbus = 0xAB in lane 2 = 0x00AB0000) *)
  access ~r1:0 ~r2:0x1000 ~inbus:0xDEAD_BEEF ~instr:0x8120_0000;
  access ~r1:0xAB ~r2:0x2000 ~inbus:0 ~instr:0xB120_0002;
  Waveform.print
    ~display_rules:
      D.
        [ port_name_is ~wave_format:Wave_format.Hex "ir"
        ; port_name_is ~wave_format:Wave_format.Hex "adr"
        ; port_name_is ~wave_format:Wave_format.Bit "rd"
        ; port_name_is ~wave_format:Wave_format.Bit "wr"
        ; port_name_is ~wave_format:Wave_format.Bit "stall"
        ; port_name_is ~wave_format:Wave_format.Hex "regmux"
        ; port_name_is ~wave_format:Wave_format.Hex "outbus"
        ]
    ~wave_width:4
    ~display_width:60
    waves;
  [%expect
    {|
    ┌Signals──────┐┌Waves──────────────────────────────────────┐
    │             ││────────────────────┬───────────────────   │
    │ir           ││ 81200000           │B1200002              │
    │             ││────────────────────┴───────────────────   │
    │             ││──────────┬─────────┬─────────┬─────────   │
    │adr          ││ 001000   │000404   │002002   │000404      │
    │             ││──────────┴─────────┴─────────┴─────────   │
    │rd           ││──────────┐                                │
    │             ││          └─────────────────────────────   │
    │wr           ││                    ┌─────────┐            │
    │             ││────────────────────┘         └─────────   │
    │stall        ││──────────┐         ┌─────────┐            │
    │             ││          └─────────┘         └─────────   │
    │             ││────────────────────┬───────────────────   │
    │regmux       ││ DEADBEEF           │80000053              │
    │             ││────────────────────┴───────────────────   │
    │             ││──────────┬─────────┬─────────┬─────────   │
    │outbus       ││ 00000000 │DEADBEEF │00AB0000 │000000AB    │
    │             ││──────────┴─────────┴─────────┴─────────   │
    └─────────────┘└───────────────────────────────────────────┘
    |}]
;;

(* The interrupt handshake. The OCaml oracle is instruction-level and models no
   interrupts, so (unlike every other slice) this is checked against the RISC5.v FSM
   directly rather than by lockstep. The full cycle: STI enables (intEnb := IR[0]); a
   one-cycle IRQ pulse latches a pending request on its rising edge (intPnd); with nothing
   stalling and not already in a handler, intAck fires — PC jumps to the vector (address
   1), intMd marks "in handler", and SPC saves [{flags, return PC}]; the handler runs;
   then RTI restores PC from SPC[21:0] and the flags from SPC[25:22] and clears intMd. We
   start from a legible PC (0x100) with C=1, so the saved SPC = 0x800103 visibly carries
   the flag (bit 23) alongside the return PC 0x103. All driver instructions are
   never-taken branches (cc=7 negated): NOP=0xCF000000, STI=0xCF000021 (IR[5], IR[0]=e),
   RTI=0xCF000010 (IR[4]). *)

let%expect_test "interrupts — STI enable, IRQ to intAck (vector 1), RTI restore \
                 [waveform]"
  =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let module Waveform = Hardcaml_waveterm.Waveform in
  let module D = Hardcaml_waveterm.Display_rule in
  let sim = Sim.create ~config:Cyclesim.Config.trace_all create in
  let waves, sim = Cyclesim.Waveform.create sim in
  let inp = Cyclesim.inputs sim in
  let reg name = some (Cyclesim.lookup_reg_by_name sim name) in
  inp.rst_n := Bits.of_unsigned_int ~width:1 1;
  inp.stall_x := Bits.of_unsigned_int ~width:1 0;
  inp.codebus := Bits.of_unsigned_int ~width:32 0;
  (* the interrupt registers power up to 0 (sim init = post-reset); start from a legible
     PC and C=1 in place of the reset StartAdr *)
  Cyclesim.Reg.of_int (reg "pc") 0x100;
  Cyclesim.Reg.of_int (reg "c") 1;
  let step ~ir ~irq =
    Cyclesim.Reg.of_int (reg "ir") ir;
    inp.irq := Bits.of_unsigned_int ~width:1 irq;
    Cyclesim.cycle sim
  in
  step ~ir:0xCF00_0021 ~irq:0;
  (* STI: intEnb <- 1; PC -> 0x101 *)
  step ~ir:0xCF00_0000 ~irq:1;
  (* IRQ: intPnd <- 1 (edge); PC -> 0x102 *)
  step ~ir:0xCF00_0000 ~irq:0;
  (* ack: PC <- 1, intMd <- 1, SPC <- 0x800103, intPnd <- 0 *)
  step ~ir:0xCF00_0000 ~irq:0;
  (* hdlr: no re-dispatch (intMd); PC -> 2 *)
  step ~ir:0xCF00_0010 ~irq:0;
  (* RTI: PC <- 0x103, intMd <- 0, C restored *)
  step ~ir:0xCF00_0000 ~irq:0;
  (* back: running at 0x103 *)
  Waveform.print
    ~display_rules:
      D.
        [ port_name_is ~wave_format:Wave_format.Hex "ir"
        ; port_name_is ~wave_format:Wave_format.Hex "pc"
        ; port_name_is ~wave_format:Wave_format.Bit "int_enb"
        ; port_name_is ~wave_format:Wave_format.Bit "int_pnd"
        ; port_name_is ~wave_format:Wave_format.Bit "int_md"
        ; port_name_is ~wave_format:Wave_format.Hex "spc"
        ]
    ~wave_width:4
    ~display_width:82
    waves;
  [%expect
    {|
    ┌Signals───────────┐┌Waves───────────────────────────────────────────────────────┐
    │                  ││──────────┬─────────────────────────────┬─────────┬─────────│
    │ir                ││ CF000021 │CF000000                     │CF000010 │CF000000 │
    │                  ││──────────┴─────────────────────────────┴─────────┴─────────│
    │                  ││──────────┬─────────┬─────────┬─────────┬─────────┬─────────│
    │pc                ││ 000100   │000101   │000102   │000001   │000002   │000103   │
    │                  ││──────────┴─────────┴─────────┴─────────┴─────────┴─────────│
    │int_enb           ││          ┌─────────────────────────────────────────────────│
    │                  ││──────────┘                                                 │
    │int_pnd           ││                    ┌─────────┐                             │
    │                  ││────────────────────┘         └─────────────────────────────│
    │int_md            ││                              ┌───────────────────┐         │
    │                  ││──────────────────────────────┘                   └─────────│
    │                  ││──────────────────────────────┬─────────────────────────────│
    │spc               ││ 0000000                      │0800103                      │
    │                  ││──────────────────────────────┴─────────────────────────────│
    └──────────────────┘└────────────────────────────────────────────────────────────┘
    |}]
;;

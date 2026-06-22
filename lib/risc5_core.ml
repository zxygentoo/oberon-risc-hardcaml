(* Public API and behaviour spec live in [risc5_core.mli].

   Implementation note. This is the CPU core — the port of RISC5.v (184 lines), the module
   AGENT.md §2 calls the crown jewel. The whole processor is a handful of registers
   updated in a single [always @(posedge clk)] block (RISC5.v:171-183), wrapped in a cloud
   of combinational logic that computes their next values. We mirror that skeleton exactly
   (§2): which signals are registered and the stall/interrupt timing are the spec the
   oracle checks and synthesis preserves; the combinational web around them is idiomatic
   Hardcaml. Each [create] line is tagged with the RISC5.v line it ports.

   It was assembled in vertical slices across Phase 4, each a green lockstep milestone:
   the fetch/decode/stall spine (PC/IR/stallL1, the decode those need, the stall
   aggregation, the next-PC mux, the memory-bus strobes — 4.0), the register file + ALU
   result mux (4.1), the multi-cycle units + H (4.2), branches (4.3), the load/store data
   path (4.4), and interrupts (4.5). Every interface port (irq, inbus, ...) is now wired.
   The interrupt FSM (4.5) has no OCaml-oracle counterpart — the oracle is interrupt-free
   — so it is checked by a co-located behavioural test against the RISC5.v spec, and
   exhaustively by the Phase-8 RTL co-sim; the instruction lockstep steers RTI/STI/CLI out
   (§8). *)

open Hardcaml
open Signal

module I = struct
  type 'a t =
    { clock : 'a
    ; rst_n : 'a [@bits 1] (* reset, active LOW (RISC5.v:5, rst); _n: see .mli *)
    ; irq : 'a [@bits 1] (* interrupt request — wired in 4.5 *)
    ; stall_x : 'a [@bits 1] (* external video-DMA stall (RISC5.v:5, stallX) *)
    ; inbus : 'a [@bits 32] (* data read bus — wired in 4.4 *)
    ; codebus : 'a [@bits 32] (* instruction fetch bus = Mem[adr] *)
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { adr : 'a [@bits 24] (* byte address: fetch, or load/store data (RISC5.v:7) *)
    ; rd : 'a [@bits 1]
    ; wr : 'a [@bits 1]
    ; ben : 'a [@bits 1] (* byte enable *)
    ; outbus : 'a [@bits 32] (* data write bus — store data *)
    }
  [@@deriving hardcaml]
end

let create (i : _ I.t) : _ O.t =
  let spec = Reg_spec.create () ~clock:i.clock in
  (* ── State registers (RISC5.v:13-17, written in the always block 171-183) ── Faithful
     no-reset registers: there is no clear port. [rst_n] (active low) reaches the datapath
     as ordinary logic (pcmux below), exactly as the RTL does it. Up now: the three
     fetch-timing registers (4.0), the condition flags N/Z/C/OV (4.1), the aux register H
     (4.2, MUL high word / DIV remainder), and the interrupt state (4.5).
     [pc]/[ir]/[stall]/[regmux], the flags, and [h] are named (--) so the waveform and
     lockstep tests can watch and poke them. *)
  let pc = Always.Variable.reg spec ~width:22 in
  let ir = Always.Variable.reg spec ~width:32 in
  let stall_l1 = Always.Variable.reg spec ~width:1 in
  let n = Always.Variable.reg spec ~width:1 in
  let z = Always.Variable.reg spec ~width:1 in
  let c = Always.Variable.reg spec ~width:1 in
  let ov = Always.Variable.reg spec ~width:1 in
  let h = Always.Variable.reg spec ~width:32 in
  (* RISC5.v:34-35 — the interrupt state (4.5): the IRQ edge-detect flop, the enable /
     pending / in-handler flags, and SPC = [{saved flags, saved PC}] (4 + 22 = 26 bits). *)
  let irq1 = Always.Variable.reg spec ~width:1 in
  let int_enb = Always.Variable.reg spec ~width:1 in
  let int_pnd = Always.Variable.reg spec ~width:1 in
  let int_md = Always.Variable.reg spec ~width:1 in
  let spc = Always.Variable.reg spec ~width:26 in
  let pc_v = pc.value -- "pc" in
  let ir_v = ir.value -- "ir" in
  let stall_l1_v = stall_l1.value in
  let n_v = n.value -- "n" in
  let z_v = z.value -- "z" in
  let c_v = c.value -- "c" in
  let ov_v = ov.value -- "ov" in
  let h_v = h.value -- "h" in
  let irq1_v = irq1.value in
  let int_enb_v = int_enb.value -- "int_enb" in
  let int_pnd_v = int_pnd.value -- "int_pnd" in
  let int_md_v = int_md.value -- "int_md" in
  let spc_v = spc.value -- "spc" in
  (* ── Instruction decode (RISC5.v:70-96) ── the mode bits, the register-op fields, and
     the op-classes the wired slices need; the rest is decoded as later slices land. *)
  let p = select ir_v ~high:31 ~low:31 in
  let q = select ir_v ~high:30 ~low:30 in
  let u = select ir_v ~high:29 ~low:29 in
  let v = select ir_v ~high:28 ~low:28 in
  let ira = select ir_v ~high:27 ~low:24 in
  let irb = select ir_v ~high:23 ~low:20 in
  let op = select ir_v ~high:19 ~low:16 in
  let irc = select ir_v ~high:3 ~low:0 in
  let imm = select ir_v ~high:15 ~low:0 in
  let cc = select ir_v ~high:26 ~low:24 in
  (* branch fields: [cc] selects the condition, [IR[27]] negates it, [disp] is the
     relative target displacement *)
  let neg = select ir_v ~high:27 ~low:27 in
  let disp = select ir_v ~high:21 ~low:0 in
  let off = select ir_v ~high:19 ~low:0 in
  (* RISC5.v:80 — the 20-bit signed load/store offset *)
  let ldr = p &: ~:q &: ~:u in
  (* RISC5.v:93 *)
  let str = p &: ~:q &: u in
  (* RISC5.v:94 *)
  let br = p &: q in
  (* RISC5.v:95 *)
  let rti = br &: ~:u &: ~:v &: select ir_v ~high:4 ~low:4 in
  (* RISC5.v:96 — RTI = BR & ~u & ~v & IR[4] (return from interrupt) *)
  let sti_cli = br &: ~:u &: ~:v &: select ir_v ~high:5 ~low:5 in
  (* RISC5.v:181 — STI/CLI = BR & ~u & ~v & IR[5]; writes intEnb := IR[0] *)
  let is_op k = ~:p &: (op ==:. k) in
  let mul = is_op 10
  and div = is_op 11
  and fad = is_op 12
  and fsb = is_op 13
  and fml = is_op 14
  and fdv = is_op 15 in
  (* RISC5.v:85-91 — the multi-cycle op-classes (run signals for the units) *)
  let stall_l0 = ldr |: str &: ~:stall_l1_v in
  (* RISC5.v:168 — the load/store stall; the full [stall] (RISC5.v:169) also ORs the unit
     stalls, so it is built below, once the units exist *)
  (* ── Operand path: register file + C1 (RISC5.v:48-49, 99-100) ── three async reads
     A/B/C0 (A is store data, wired in 4.4); the write port commits [regmux] to R[ira0] at
     the edge. That read->compute->write is a loop the sequential write breaks, so [din]
     is a forward [wire] assigned once [regmux] exists. *)
  let ira0 = mux2 br (of_unsigned_int ~width:4 15) ira in
  (* RISC5.v:99 — a branch links PC+1 to R15 *)
  let regmux_w = wire 32 in
  let regwr_w = wire 1 in
  (* [regwr] = ~p & ~stall needs the full [stall] (unit stalls, below), but the register
     file's write enable is wanted here — a forward [wire], like [regmux]. *)
  let regs =
    Registers.create
      { Registers.I.clock = i.clock
      ; wr = regwr_w
      ; rno0 = ira0
      ; rno1 = irb
      ; rno2 = irc
      ; din = regmux_w
      }
  in
  let a = regs.dout0 in
  let b = regs.dout1 in
  let c0 = regs.dout2 in
  let c1 = mux2 q (repeat v ~count:16 @: imm) c0 in
  (* RISC5.v:100 — C1 = q ? {{16{v}}, imm} : C0 *)
  let shamt = sel_bottom c1 ~width:5 in
  (* C1[4:0] — the shift count *)
  (* ── Arithmetic units + result mux (RISC5.v:57,59,106-125) ── B/C1 fan out every cycle
     to the combinational shifters and ALU (the MOV/logic/ADD-SUB unit) and to the
     multi-cycle units (below); the mux selects one result by [op]. *)
  let { Left_shifter.O.y = lshout } =
    Left_shifter.create { Left_shifter.I.x = b; sc = shamt }
  in
  let { Right_shifter.O.y = rshout } =
    Right_shifter.create { Right_shifter.I.x = b; sc = shamt; md = lsb op }
  in
  let { Alu.O.res = alu_res; c = alu_c; ov = alu_ov } =
    Alu.create
      { Alu.I.op
      ; u
      ; q
      ; v
      ; imm
      ; b
      ; c1
      ; h = h_v (* H = MUL high word / DIV remainder; the MOV' H-read source *)
      ; n_in = n_v
      ; z_in = z_v
      ; c_in = c_v
      ; ov_in = ov_v
      }
  in
  (* ── The multi-cycle units (RISC5.v:51-68) ── MUL/DIV take B/C1 and the *inverted*
     u-bit ([~u]: signed MUL/DIV is u=1, RISC5.v:52/55). The FP units are
     register-register, so operand 2 is C0 (not C1); FSB reuses the adder with operand 2's
     sign bit flipped ([{FSB^C0[31], C0[30:0]}], RISC5.v:62). Each asserts [stall] until
     its counter ends. *)
  let { Multiplier.O.stall = stall_m; z = product } =
    Multiplier.create { Multiplier.I.clock = i.clock; run = mul; u = ~:u; x = b; y = c1 }
  in
  let { Divider.O.stall = stall_d; quot = quotient; rem = remainder } =
    Divider.create { Divider.I.clock = i.clock; run = div; u = ~:u; x = b; y = c1 }
  in
  let fsb_y = (fsb ^: msb c0) @: select c0 ~high:30 ~low:0 in
  let { Fp_adder.O.stall = stall_fa; z = fsum } =
    Fp_adder.create
      { Fp_adder.I.clock = i.clock; run = fad |: fsb; u; v; x = b; y = fsb_y }
  in
  let { Fp_multiplier.O.stall = stall_fm; z = fprod } =
    Fp_multiplier.create { Fp_multiplier.I.clock = i.clock; run = fml; x = b; y = c0 }
  in
  let { Fp_divider.O.stall = stall_fd; z = fquot } =
    Fp_divider.create { Fp_divider.I.clock = i.clock; run = fdv; x = b; y = c0 }
  in
  let res =
    mux
      op
      [ alu_res (* 0 MOV *)
      ; lshout (* 1 LSL *)
      ; rshout (* 2 ASR *)
      ; rshout (* 3 ROR *)
      ; alu_res (* 4 AND *)
      ; alu_res (* 5 ANN *)
      ; alu_res (* 6 IOR *)
      ; alu_res (* 7 XOR *)
      ; alu_res (* 8 ADD *)
      ; alu_res (* 9 SUB *)
      ; sel_bottom product ~width:32 (* 10 MUL — product[31:0] *)
      ; quotient (* 11 DIV *)
      ; fsum (* 12 FAD *)
      ; fsum (* 13 FSB *)
      ; fprod (* 14 FML *)
      ; fquot (* 15 FDV *)
      ]
  in
  (* full stall (RISC5.v:169): load/store + external + every unit's stall *)
  let stall_all =
    stall_l0 |: i.stall_x |: stall_m |: stall_d |: stall_fa |: stall_fm |: stall_fd
  in
  let stall = stall_all -- "stall" in
  (* RISC5.v:149 — acknowledge an interrupt when one is pending and enabled, we're not
     already inside a handler ([~int_md]), and nothing is stalling. The [~stall] gate
     keeps the about-to-be-saved PC coherent (no half-finished multi-cycle op). *)
  let int_ack = int_pnd_v &: int_enb_v &: ~:int_md_v &: ~:stall in
  (* ── Memory address + load byte-lane (RISC5.v:101,104,128-130) ── the data address is
     B[23:0] + sign-extended off; [ben] is the byte enable. A byte load selects the lane
     at [data_adr[1:0]] from inbus and zero-extends; a word load passes inbus through.
     (data_adr is the output [adr] during a load/store, so its low 2 bits are adr[1:0].) *)
  let data_adr = sel_bottom b ~width:24 +: sresize off ~width:24 in
  (* RISC5.v:101 — B[23:0] + {{4{off[19]}}, off} *)
  let ben = p &: ~:q &: v &: ~:(i.stall_x) &: ~:stall_l1_v in
  (* RISC5.v:104 — byte enable *)
  let byte_lane = sel_bottom data_adr ~width:2 in
  let load_byte =
    mux
      byte_lane
      [ select i.inbus ~high:7 ~low:0
      ; select i.inbus ~high:15 ~low:8
      ; select i.inbus ~high:23 ~low:16
      ; select i.inbus ~high:31 ~low:24
      ]
  in
  let inbus1 = mux2 ben (zero 24 @: load_byte) i.inbus in
  (* RISC5.v:128-130 *)
  (* ── Control unit: condition + next PC (RISC5.v:137-153) ── [cond] is the branch
     condition (the §7 cc table, negated by IR[27]); [pcmux0] sends a taken branch to its
     target (PC+1+disp relative, or R.c>>2 register) and falls through to nxpc otherwise.
     The intAck/RTI terms of [pcmux] layer in with interrupts (4.5). *)
  let nxpc = pc_v +:. 1 in
  (* RISC5.v:138 *)
  let s = n_v ^: ov_v in
  (* RISC5.v:137 — S = N ^ OV *)
  let cond =
    neg
    ^: mux
         cc
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
  (* RISC5.v:139-147 *)
  let pcmux0 =
    mux2 (br &: cond) (mux2 u (nxpc +: disp) (select c0 ~high:23 ~low:2)) nxpc
  in
  (* RISC5.v:153 *)
  (* ── Writeback + flags (RISC5.v:127,131,155-166) ── [regmux] is the written-back value:
     a taken linking branch ([BR & v]) writes the return byte-address [{PC+1, 2'b0}] to
     R15 (= [ira0]); otherwise the ALU/unit result. (The LDR form joins at 4.4.) [regwr]
     gains the branch-link enable. N/Z from the written value, C/OV from the ALU;
     RTI-restore in 4.5. *)
  let link = zero 8 @: nxpc @: zero 2 in
  (* RISC5.v:131 — {8'b0, nxpc, 2'b0}, the return byte address *)
  let regmux = mux2 ldr inbus1 (mux2 (br &: v) link res) -- "regmux" in
  assign regmux_w regmux;
  let regwr =
    ~:p
    &: ~:stall
    |: (br &: cond &: v &: ~:(i.stall_x))
    |: (ldr &: ~:(i.stall_x) &: ~:stall_l1_v)
  in
  (* RISC5.v:127 — a register op (not stalled), a taken linking branch, or a load (which
     writes the fetched data on its [stallL0] cycle) *)
  assign regwr_w regwr;
  let nn = mux2 rti (select spc_v ~high:25 ~low:25) (mux2 regwr (msb regmux) n_v) in
  (* RISC5.v:159 — RTI restores N from SPC[25], else N from the writeback / hold *)
  let zz = mux2 rti (select spc_v ~high:24 ~low:24) (mux2 regwr (regmux ==:. 0) z_v) in
  (* RISC5.v:160 — RTI restores Z from SPC[24] *)
  let cx = mux2 rti (select spc_v ~high:23 ~low:23) alu_c in
  (* RISC5.v:161-163 — RTI restores C from SPC[23], else the ALU's add/sub carry *)
  let vv = mux2 rti (select spc_v ~high:22 ~low:22) alu_ov in
  (* RISC5.v:164-166 — RTI restores OV from SPC[22], else the ALU's add/sub overflow *)
  let h_next = mux2 mul (select product ~high:63 ~low:32) (mux2 div remainder h_v) in
  (* RISC5.v:176 — H <= MUL ? product[63:32] : DIV ? remainder : H *)
  (* ── Interrupt next-state (RISC5.v:178-182) ── on intAck, SPC latches
     [{flags, return PC}]; intPnd sets on a rising IRQ edge and clears on intAck; intMd
     marks "in handler" (set on intAck, cleared by RTI); intEnb is reset-cleared and
     written by STI/CLI. The [rst_n &] / [~rst_n ?] guards are RISC5.v's [rst &] /
     [~rst ?] (rst is active-low). *)
  let spc_next = mux2 int_ack (nn @: zz @: cx @: vv @: pcmux0) spc_v in
  (* RISC5.v:182 — {nn, zz, cx, vv, pcmux0}: the flags about to be set + the return PC *)
  let int_pnd_next = i.rst_n &: ~:int_ack &: (~:irq1_v &: i.irq |: int_pnd_v) in
  (* RISC5.v:179 — set on the rising IRQ edge [~irq1 & irq], cleared on intAck *)
  let int_md_next = i.rst_n &: ~:rti &: (int_ack |: int_md_v) in
  (* RISC5.v:180 *)
  let int_enb_next = mux2 ~:(i.rst_n) (zero 1) (mux2 sti_cli (lsb ir_v) int_enb_v) in
  (* RISC5.v:181 — IR[0] = the e bit of STI/CLI *)
  let start_adr = of_unsigned_int ~width:22 0x3F_F800 in
  (* RISC5.v:11, StartAdr *)
  let spc_pc = select spc_v ~high:21 ~low:0 in
  (* RISC5.v:152 — the return PC lives in SPC[21:0] *)
  let pcmux =
    mux2
      ~:(i.rst_n)
      start_adr
      (mux2
         stall
         pc_v
         (mux2 int_ack (of_unsigned_int ~width:22 1) (mux2 rti spc_pc pcmux0)))
  in
  (* RISC5.v:150-152 — priority reset > stall > intAck (→ vector address 1) > RTI (→
     restore SPC[21:0]) > branch/step. intAck is [~stall]-gated, so it never collides with
     the stall term above it. *)
  (* ── Memory bus (RISC5.v:101-104,132-134) ── [adr] is the data address while [stallL0],
     else the fetch address; [outbus] is the store data — A for a word store, or A[7:0]
     replicated into the addressed byte lane for a byte store. *)
  let adr = mux2 stall_l0 data_adr (pcmux @: zero 2) in
  (* RISC5.v:101 *)
  let rd = ldr &: ~:(i.stall_x) &: ~:stall_l1_v in
  (* RISC5.v:102 *)
  let wr = str &: ~:(i.stall_x) &: ~:stall_l1_v in
  (* RISC5.v:103 *)
  let a8 = sel_bottom a ~width:8 in
  let store_byte =
    mux
      byte_lane
      [ zero 24 @: a8 (* lane 0 *)
      ; zero 16 @: a8 @: zero 8 (* lane 1 *)
      ; zero 8 @: a8 @: zero 16 (* lane 2 *)
      ; a8 @: zero 24 (* lane 3 *)
      ]
  in
  let outbus = mux2 ben store_byte a in
  (* RISC5.v:132-134 *)
  (* ── Sequential update — the one always block (RISC5.v:171-183) ── this list grows to
     all twelve registers as the slices land; today the fetch-timing registers and flags. *)
  Always.(
    compile
      [ pc <-- pcmux (* RISC5.v:172 *)
      ; ir <-- mux2 stall ir_v i.codebus (* RISC5.v:173 *)
      ; stall_l1 <-- mux2 i.stall_x stall_l1_v stall_l0 (* RISC5.v:174 *)
      ; n <-- nn (* RISC5.v:175 *)
      ; z <-- zz
      ; c <-- cx
      ; ov <-- vv
      ; h <-- h_next (* RISC5.v:176 *)
      ; irq1 <-- i.irq (* RISC5.v:178 — the IRQ edge-detect flop *)
      ; int_pnd <-- int_pnd_next (* RISC5.v:179 *)
      ; int_md <-- int_md_next (* RISC5.v:180 *)
      ; int_enb <-- int_enb_next (* RISC5.v:181 *)
      ; spc <-- spc_next (* RISC5.v:182 *)
      ]);
  { O.adr; rd; wr; ben; outbus }
;;

(* ── Tests (co-located; AGENT.md §6) ────────────────────────────────────────── 4.0 has
   no architectural result to lockstep yet (the datapath lands in 4.1), so the milestone
   is a behaviour waveform of the fetch/stall spine: reset loads StartAdr, PC marches
   through fetched instructions, a load asserts a one-cycle stall (PC/IR freeze, rd
   pulses, the 2-cycle access), and the external stall_x freezes the core the same way.
   The internal pc/ir/stall are traced (Cyclesim.Config.trace_all + the (--) names above). *)

let%expect_test "fetch spine — reset, PC march, load stall, external stall [waveform]" =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let module Waveform = Hardcaml_waveterm.For_cyclesim.Waveform in
  let module D = Hardcaml_waveterm.Display_rule in
  let sim = Sim.create ~config:Cyclesim.Config.trace_all create in
  let waves, sim = Waveform.create sim in
  let inp = Cyclesim.inputs sim in
  let set r v w = r := Bits.of_unsigned_int ~width:w v in
  let step ~rst_n ~stall_x ~codebus =
    set inp.rst_n rst_n 1;
    set inp.stall_x stall_x 1;
    set inp.codebus codebus 32;
    Cyclesim.cycle sim
  in
  (* one reset cycle (rst_n=0), then fetch register ops (p=0, no stall); a LDR
     (p=1,q=0,u=0 -> 0x8000_0000) shows the 2-cycle access — stall+rd for a cycle while
     PC/IR freeze — and a stall_x pulse shows the external freeze. The codebus payloads
     are arbitrary: 4.0 only decodes the class bits, it does not execute. (In the real
     machine codebus = Mem[adr], so the frozen adr re-fetches the same word during a
     stall; here it is free-driven, so the stalled payloads are simply not latched.) *)
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

(* 4.1 — the register-op datapath computes and writes back. Not lockstep (that is the
   oracle's job, test/), but a visible check that MOV/ADD/SUB flow through the register
   file, result mux, and flags. A tiny straight-line program, each instruction fed on
   codebus and executing the next cycle (no stalls), reading back what the prior ones
   wrote (async read / sync write, no hazard). regmux is the writeback value; the flags
   are *registered*, so N/Z/C/OV land the cycle after the result they reflect. *)

let%expect_test "register ops — MOV/ADD/SUB compute, write back, set flags [waveform]" =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let module Waveform = Hardcaml_waveterm.For_cyclesim.Waveform in
  let module D = Hardcaml_waveterm.Display_rule in
  let sim = Sim.create ~config:Cyclesim.Config.trace_all create in
  let waves, sim = Waveform.create sim in
  let inp = Cyclesim.inputs sim in
  let set r v w = r := Bits.of_unsigned_int ~width:w v in
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

(* 4.2 — a multi-cycle op (MUL) freezes the whole core. We poke operands + a signed MUL
   R3,R1,R2 (7*6=42) and run it to completion: the multiplier asserts [stall], which holds
   PC and IR frozen for 33 cycles (the unit's state counter running), then on the cycle
   [stall] drops the result mux's product[31:0] writes back (regmux) and product[63:32]
   lands in H. DIV/FP work identically through the same stall path. The product is too
   wide for a tight window, so we show the head (stall onset, PC/IR frozen) and the tail
   (stall drops, the writeback). *)

let%expect_test "MUL — the core stalls, PC/IR freeze, then product + H write back \
                 [waveform]"
  =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let module Waveform = Hardcaml_waveterm.For_cyclesim.Waveform in
  let module D = Hardcaml_waveterm.Display_rule in
  let some = function
    | Some x -> x
    | None -> failwith "lookup"
  in
  let sim = Sim.create ~config:Cyclesim.Config.trace_all create in
  let waves, sim = Waveform.create sim in
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
    ~display_width:70
    waves;
  [%expect
    {|
    ┌Signals────────┐┌Waves──────────────────────────────────────────────┐
    │               ││──────────────────────────────                     │
    │ir             ││ 031A0002                                          │
    │               ││──────────────────────────────                     │
    │               ││──────────────────────────────                     │
    │pc             ││ 000100                                            │
    │               ││──────────────────────────────                     │
    │stall          ││────────────────────┐                              │
    │               ││                    └─────────                     │
    │               ││──────────┬─────────┬─────────                     │
    │regmux         ││ 000000A8 │00000054 │0000002A                      │
    │               ││──────────┴─────────┴─────────                     │
    │               ││──────────────────────────────                     │
    │h              ││ 00000000                                          │
    │               ││──────────────────────────────                     │
    └───────────────┘└───────────────────────────────────────────────────┘
    |}]
;;

(* 4.3 — a branch changes PC instead of writing a register. We poke a taken relative
   branch-and-link (BL) and a not-taken conditional, each run two cycles so the PC
   register shows the post-branch value: the BL's regmux is the return byte-address
   [{PC+1,2'b0}] (the link, written to R15) and PC jumps to nxpc+disp; the not-taken
   branch's regmux is the unwritten ALU result and PC simply falls through to nxpc. *)

let%expect_test "branches — taken BL (jump + link) vs not-taken (fall-through) [waveform]"
  =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let module Waveform = Hardcaml_waveterm.For_cyclesim.Waveform in
  let module D = Hardcaml_waveterm.Display_rule in
  let some = function
    | Some x -> x
    | None -> failwith "lookup"
  in
  let sim = Sim.create ~config:Cyclesim.Config.trace_all create in
  let waves, sim = Waveform.create sim in
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

(* 4.4 — a load/store is a 2-cycle access: the stallL0 cycle drives the data address B+off
   and the rd/wr strobe (PC/IR frozen), then a bubble cycle. We poke a word load (R1 <-
   inbus, the byte-lane select gives the whole word) and a byte store (outbus = R1[7:0]
   replicated into the addressed lane). regmux is the load writeback; outbus the store
   data. *)

let%expect_test "load/store — 2-cycle access: data adr, rd/wr, byte lane [waveform]" =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let module Waveform = Hardcaml_waveterm.For_cyclesim.Waveform in
  let module D = Hardcaml_waveterm.Display_rule in
  let some = function
    | Some x -> x
    | None -> failwith "lookup"
  in
  let sim = Sim.create ~config:Cyclesim.Config.trace_all create in
  let waves, sim = Waveform.create sim in
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

(* 4.5 — the interrupt handshake. The OCaml oracle is instruction-level and models no
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
  let module Waveform = Hardcaml_waveterm.For_cyclesim.Waveform in
  let module D = Hardcaml_waveterm.Display_rule in
  let some = function
    | Some x -> x
    | None -> failwith "lookup"
  in
  let sim = Sim.create ~config:Cyclesim.Config.trace_all create in
  let waves, sim = Waveform.create sim in
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

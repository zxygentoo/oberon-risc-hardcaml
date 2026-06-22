(* Public API and behaviour spec live in [risc5_core.mli].

   Implementation note. This is the CPU core — the port of RISC5.v (184 lines), the module
   AGENT.md §2 calls the crown jewel. The whole processor is a handful of registers
   updated in a single [always @(posedge clk)] block (RISC5.v:171-183), wrapped in a cloud
   of combinational logic that computes their next values. We mirror that skeleton exactly
   (§2): which signals are registered and the stall/interrupt timing are the spec the
   oracle checks and synthesis preserves; the combinational web around them is idiomatic
   Hardcaml. Each [create] line is tagged with the RISC5.v line it ports.

   It is assembled in vertical slices across Phase 4, each a green lockstep milestone.
   This is the fetch/decode/stall spine: PC/IR/stallL1, the decode those need, the stall
   aggregation, the next-PC mux, and the memory-bus control strobes. Layering in later:
   the register file + ALU result mux (4.1), the multi-cycle units + H (4.2), branches
   (4.3), the load/store data path (4.4), and interrupts (4.5). Bindings the later slices
   read off the interface (irq, inbus) are already ports but not yet wired. *)

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
     fetch-timing registers (4.0), the condition flags N/Z/C/OV (4.1), and the aux
     register H (4.2, MUL high word / DIV remainder); the interrupt state joins in 4.5.
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
  let pc_v = pc.value -- "pc" in
  let ir_v = ir.value -- "ir" in
  let stall_l1_v = stall_l1.value in
  let n_v = n.value -- "n" in
  let z_v = z.value -- "z" in
  let c_v = c.value -- "c" in
  let ov_v = ov.value -- "ov" in
  let h_v = h.value -- "h" in
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
  let ldr = p &: ~:q &: ~:u in
  (* RISC5.v:93 *)
  let str = p &: ~:q &: u in
  (* RISC5.v:94 *)
  let br = p &: q in
  (* RISC5.v:95 *)
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
  let regmux = mux2 (br &: v) link res -- "regmux" in
  assign regmux_w regmux;
  let regwr = ~:p &: ~:stall |: (br &: cond &: v &: ~:(i.stall_x)) in
  (* RISC5.v:127 (partial) — a register op (not stalled), or a taken linking branch; the
     LDR term joins at 4.4 *)
  assign regwr_w regwr;
  let nn = mux2 regwr (msb regmux) n_v in
  (* RISC5.v:159 *)
  let zz = mux2 regwr (regmux ==:. 0) z_v in
  (* RISC5.v:160 *)
  let cx = alu_c in
  (* RISC5.v:161-163 *)
  let vv = alu_ov in
  (* RISC5.v:164-166 *)
  let h_next = mux2 mul (select product ~high:63 ~low:32) (mux2 div remainder h_v) in
  (* RISC5.v:176 — H <= MUL ? product[63:32] : DIV ? remainder : H *)
  let start_adr = of_unsigned_int ~width:22 0x3F_F800 in
  (* RISC5.v:11, StartAdr *)
  let pcmux = mux2 ~:(i.rst_n) start_adr (mux2 stall pc_v pcmux0) in
  (* ── Memory bus (RISC5.v:101-104) ── the control strobes are final; [adr]'s load/store
     data-address branch ([stallL0 ? B+off]) and [outbus]'s store data arrive with the
     load/store data path in 4.4, so [adr] is the fetch address and [outbus] is 0 for now. *)
  let adr = pcmux @: zero 2 in
  (* RISC5.v:101 (fetch path) *)
  let rd = ldr &: ~:(i.stall_x) &: ~:stall_l1_v in
  (* RISC5.v:102 *)
  let wr = str &: ~:(i.stall_x) &: ~:stall_l1_v in
  (* RISC5.v:103 *)
  let ben = p &: ~:q &: v &: ~:(i.stall_x) &: ~:stall_l1_v in
  (* RISC5.v:104 *)
  let outbus = a in
  (* RISC5.v:132 — outbus = A (the ~ben case); the byte-lane mux for byte stores joins in
     4.4 *)
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
    │                  ││──────────┬─────────┬───────────────────┬───────────────────┬───────── │
    │adr               ││ FFE000   │FFE004   │FFE008             │FFE00C             │FFE010    │
    │                  ││──────────┴─────────┴───────────────────┴───────────────────┴───────── │
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

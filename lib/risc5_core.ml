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
     fetch-timing registers (4.0) and the condition flags N/Z/C/OV (4.1); [H] joins with
     MUL/DIV (4.2), the interrupt state in 4.5. [pc]/[ir]/[stall] and the flags are named
     (--) so the waveform tests can watch them. *)
  let pc = Always.Variable.reg spec ~width:22 in
  let ir = Always.Variable.reg spec ~width:32 in
  let stall_l1 = Always.Variable.reg spec ~width:1 in
  let n = Always.Variable.reg spec ~width:1 in
  let z = Always.Variable.reg spec ~width:1 in
  let c = Always.Variable.reg spec ~width:1 in
  let ov = Always.Variable.reg spec ~width:1 in
  let pc_v = pc.value -- "pc" in
  let ir_v = ir.value -- "ir" in
  let stall_l1_v = stall_l1.value in
  let n_v = n.value -- "n" in
  let z_v = z.value -- "z" in
  let c_v = c.value -- "c" in
  let ov_v = ov.value -- "ov" in
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
  let ldr = p &: ~:q &: ~:u in
  (* RISC5.v:93 *)
  let str = p &: ~:q &: u in
  (* RISC5.v:94 *)
  let br = p &: q in
  (* RISC5.v:95 *)
  (* ── Stall aggregation (RISC5.v:168-169) ── the multi-cycle unit stalls (M/D/FA/FM/FD)
     OR into [stall] in 4.2; for now it is the load/store stall and the external stall. *)
  let stall_l0 = ldr |: str &: ~:stall_l1_v in
  (* RISC5.v:168 *)
  let stall = (stall_l0 |: i.stall_x) -- "stall" in
  (* RISC5.v:169 (partial) *)
  (* ── Operand path: register file + C1 (RISC5.v:48-49, 99-100) ── three async reads
     A/B/C0 (A is store data, wired in 4.4); the write port commits [regmux] to R[ira0] at
     the edge. That read->compute->write is a loop the sequential write breaks, so [din]
     is a forward [wire] assigned once [regmux] exists. *)
  let ira0 = mux2 br (of_unsigned_int ~width:4 15) ira in
  (* RISC5.v:99 — a branch links PC+1 to R15 *)
  let regmux_w = wire 32 in
  let regwr = ~:p &: ~:stall in
  (* RISC5.v:127 (partial) — a register op writes when not stalled; LDR/BR terms at
     4.3/4.4 *)
  let regs =
    Registers.create
      { Registers.I.clock = i.clock
      ; wr = regwr
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
  (* ── Arithmetic units + result mux (RISC5.v:57,59,106-125) ── B/C1 fan out to the
     shifters and the ALU (the MOV/logic/ADD-SUB unit, already built) every cycle; the mux
     selects one by [op]. The MUL/DIV/FP slots read 0 until their units land in 4.2. *)
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
      ; h = zero 32 (* H register + MUL/DIV-high join in 4.2 *)
      ; n_in = n_v
      ; z_in = z_v
      ; c_in = c_v
      ; ov_in = ov_v
      }
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
      ; zero 32 (* 10 MUL — 4.2 *)
      ; zero 32 (* 11 DIV — 4.2 *)
      ; zero 32 (* 12 FAD — 4.2 *)
      ; zero 32 (* 13 FSB — 4.2 *)
      ; zero 32 (* 14 FML — 4.2 *)
      ; zero 32 (* 15 FDV — 4.2 *)
      ]
  in
  (* ── Writeback + flags (RISC5.v:131,155-166) ── [regmux] is the value written back: the
     ALU result for a register op (the LDR/BR forms join at 4.3/4.4). N/Z derive from the
     written value, C/OV from the ALU's arithmetic flags (ADD/SUB set them, else pass
     through); the RTI-restore term on each is added with interrupts in 4.5. *)
  let regmux = res -- "regmux" in
  (* RISC5.v:131 *)
  assign regmux_w regmux;
  let nn = mux2 regwr (msb regmux) n_v in
  (* RISC5.v:159 *)
  let zz = mux2 regwr (regmux ==:. 0) z_v in
  (* RISC5.v:160 *)
  let cx = alu_c in
  (* RISC5.v:161-163 *)
  let vv = alu_ov in
  (* RISC5.v:164-166 *)
  (* ── Control unit: next PC (RISC5.v:138, 150-153) ── 4.0 keeps the reset/stall/step
     ladder; intAck, RTI, and the branch target layer in at 4.3 (branches) / 4.5 (ints). *)
  let nxpc = pc_v +:. 1 in
  (* RISC5.v:138 *)
  let start_adr = of_unsigned_int ~width:22 0x3F_F800 in
  (* RISC5.v:11, StartAdr *)
  let pcmux = mux2 ~:(i.rst_n) start_adr (mux2 stall pc_v nxpc) in
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

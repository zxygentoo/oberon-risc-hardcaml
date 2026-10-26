(* The RISC5 core, a port of RISC5.v. The contract is in [cpu.mli].

   The processor is thirteen registers updated in one clocked block (the [Always.compile]
   at the end of [create_with_units]) and the combinational logic that computes their next
   values. The registers and their stall and interrupt timing mirror the RTL exactly; the
   combinational part is ordinary Hardcaml. [create_with_units] reads top to bottom as the
   loop: decode, fetch operands, execute, memory, control, writeback, commit.

   The oracle models no interrupts, so the lockstep cannot check the interrupt logic: the
   waveform test at the end of this file and the formal core proof do. *)

open Hardcaml
open Signal

module I = struct
  type 'a t =
    { clock : 'a
    ; rst_n : 'a [@bits 1]
    ; irq : 'a [@bits 1]
    ; stall_x : 'a [@bits 1]
    ; inbus : 'a [@bits 32]
    ; codebus : 'a [@bits 32]
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { adr : 'a [@bits 24]
    ; rd : 'a [@bits 1]
    ; wr : 'a [@bits 1]
    ; ben : 'a [@bits 1]
    ; outbus : 'a [@bits 32]
    ; mem_pend : 'a [@bits 1]
    }
  [@@deriving hardcaml]
end

(* everything that follows from the IR word alone *)
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
  ; off : Signal.t (* the load/store offset, 20 bits signed *)
  ; ldr : Signal.t
  ; str : Signal.t
  ; br : Signal.t
  ; rti : Signal.t (* return from interrupt *)
  ; sti_cli : Signal.t (* intEnb := IR[0] *)
  ; mul : Signal.t (* op 10..15: the multi-cycle operations *)
  ; div : Signal.t
  ; fad : Signal.t
  ; fsb : Signal.t
  ; fml : Signal.t
  ; fdv : Signal.t
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

  (* The five iterative units freeze with the core under [ce]. The shifters are
     combinational and the register file's write is gated in the core, so neither takes
     it. *)
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

type execute_out =
  { result : Signal.t
  ; alu_c : Signal.t
  ; alu_ov : Signal.t
  ; product_hi : Signal.t
  ; remainder : Signal.t
  ; unit_stall : Signal.t
  }

(* Every unit computes every cycle and [op] selects one result. MUL and DIV take the
   inverted u bit (their [u] means signed). The FP units' second operand is the register
   C0, never the immediate, and FSB is FAD with that operand's sign flipped. *)
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
      ; sel_bottom mul.z ~width:32 (* 10 MUL *)
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

type memory_out =
  { load_data : Signal.t
  ; data_adr : Signal.t
  ; read : Signal.t
  ; write : Signal.t
  ; byte_en : Signal.t
  ; stall_l0 : Signal.t
  ; store_data : Signal.t
  }

(* The data address is B plus the sign-extended offset. A byte access selects the lane at
   adr[1:0]: a load zero-extends it, a store lifts A's low byte into it. A load or store
   takes two cycles, and [stall_l0] is the first. *)
let memory ~(dec : decoded) ~a ~b ~inbus ~stall_x ~stall_l1 : memory_out =
  (* named before it is and-ed: [&:] and [|:] have equal precedence *)
  let ld_or_st = dec.ldr |: dec.str in
  let stall_l0 = ld_or_st &: ~:stall_l1 in
  let not_stalled = ~:stall_x &: ~:stall_l1 in
  let data_adr = sel_bottom b ~width:24 +: sresize dec.off ~width:24 in
  let ben = ld_or_st &: dec.v &: not_stalled in
  let byte_lane = sel_bottom data_adr ~width:2 in
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

(* RISC5.v's StartAdr, a word address *)
let start_adr = 0x3F_F800

let create_with_units ?(ce = vdd) ~(units : Units.t) (i : _ I.t) : _ O.t =
  let spec = Reg_spec.create () ~clock:i.clock in
  (* ── State ── Registers without reset, as in the RTL: [rst_n] reaches them as ordinary
     logic, through [pcmux] and the interrupt next-state. They carry the RTL's names: the
     tests and the proofs reach them by name. *)
  let pc = Always.Variable.reg spec ~enable:ce ~width:22 in
  let ir = Always.Variable.reg spec ~enable:ce ~width:32 in
  let stall_l1 = Always.Variable.reg spec ~enable:ce ~width:1 in
  let n = Always.Variable.reg spec ~enable:ce ~width:1 in
  let z = Always.Variable.reg spec ~enable:ce ~width:1 in
  let c = Always.Variable.reg spec ~enable:ce ~width:1 in
  let ov = Always.Variable.reg spec ~enable:ce ~width:1 in
  let h = Always.Variable.reg spec ~enable:ce ~width:32 in
  let irq1 = Always.Variable.reg spec ~enable:ce ~width:1 in
  let int_enb = Always.Variable.reg spec ~enable:ce ~width:1 in
  let int_pnd = Always.Variable.reg spec ~enable:ce ~width:1 in
  let int_md = Always.Variable.reg spec ~enable:ce ~width:1 in
  (* {saved flags, saved PC}: 4 + 22 bits *)
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
  let dec = decode ir_v in
  (* ── Fetch operands ── The register file reads combinationally and writes at the edge.
     What it writes is computed from what it reads, so its [din]/[wr] are wires, closed in
     the writeback below. A is the store data; a branch links through R15. *)
  let ira0 = mux2 dec.br (of_unsigned_int ~width:4 15) dec.ira in
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
  (* operand 2: the immediate extended with sixteen v bits, or C0 *)
  let c1 = mux2 dec.q (repeat dec.v ~count:16 @: dec.imm) c0 in
  let shamt = sel_bottom c1 ~width:5 in
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
  let mem = memory ~dec ~a ~b ~inbus:i.inbus ~stall_x:i.stall_x ~stall_l1:stall_l1_v in
  (* ── Control ── An interrupt is acknowledged when it is pending and enabled, outside a
     handler, on a cycle that is not stalled. *)
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
  (* ── Writeback ── *)
  (* the return address, in bytes *)
  let link = zero 8 @: nxpc @: zero 2 in
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
  (* a register operation that is not stalled, a taken linking branch, or a load; gated by
     [ce] so that nothing commits during a memory wait *)
  assign regwr_w (regwr &: ce);
  (* N and Z follow the written value, C and OV the ALU; RTI restores all four *)
  let nn = mux2 dec.rti (bit spc_v ~pos:25) (mux2 regwr (msb regmux) n_v) in
  let zz = mux2 dec.rti (bit spc_v ~pos:24) (mux2 regwr (regmux ==:. 0) z_v) in
  let cx = mux2 dec.rti (bit spc_v ~pos:23) exe.alu_c in
  let vv = mux2 dec.rti (bit spc_v ~pos:22) exe.alu_ov in
  let h_next = mux2 dec.mul exe.product_hi (mux2 dec.div exe.remainder h_v) in
  (* ── Interrupt state ── A request is pending from a rising edge of [irq] until it is
     acknowledged; [int_md] marks the handler, from the acknowledge to RTI. *)
  let spc_next = mux2 int_ack (nn @: zz @: cx @: vv @: pcmux0) spc_v in
  let int_pnd_next = i.rst_n &: ~:int_ack &: (~:irq1_v &: i.irq |: int_pnd_v) in
  let int_md_next = i.rst_n &: ~:(dec.rti) &: (int_ack |: int_md_v) in
  let int_enb_next = mux2 ~:(i.rst_n) (zero 1) (mux2 dec.sti_cli (lsb ir_v) int_enb_v) in
  (* ── Next PC ── In priority order: reset, stall, an acknowledged interrupt (the vector
     is address 1), RTI, then the branch or the next instruction. *)
  let start_pc = of_unsigned_int ~width:22 start_adr in
  let spc_pc = select spc_v ~high:21 ~low:0 in
  let pcmux =
    mux2
      ~:(i.rst_n)
      start_pc
      (mux2
         stall
         pc_v
         (mux2 int_ack (of_unsigned_int ~width:22 1) (mux2 dec.rti spc_pc pcmux0)))
  in
  (* ── Commit ── *)
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
  (* ── Bus ── the data address in the first load/store cycle, else the fetch address *)
  let adr = mux2 mem.stall_l0 mem.data_adr (pcmux @: zero 2) in
  (* a fetch or a data access: every cycle but a pure compute stall *)
  let mem_pend = mem.stall_l0 |: ~:stall in
  { O.adr
  ; rd = mem.read
  ; wr = mem.write
  ; ben = mem.byte_en
  ; outbus = mem.store_data
  ; mem_pend
  }
;;

type multipliers =
  | Iterative
  | Dsp of { stages : int }

let create ?(ce = vdd) ?(multipliers = Iterative) i =
  (* the integer and the FP multiply are swapped together *)
  let units = Units.with_ce ce in
  let units =
    match multipliers with
    | Iterative -> units
    | Dsp { stages = 0 } ->
      { units with
        multiplier = Multiplier.create_opt ~ce
      ; fp_multiplier = Fp_multiplier.create_opt ~ce
      }
    | Dsp { stages } ->
      { units with
        multiplier = Multiplier.create_opt_pipelined ~ce ~stages
      ; fp_multiplier = Fp_multiplier.create_opt_pipelined ~ce ~stages
      }
  in
  create_with_units ~ce ~units i
;;

(* ── Tests ── Waveforms of the core's timing. Its results are checked against the oracle
   by the lockstep in test/. *)

let set r v w = r := Bits.of_unsigned_int ~width:w v

let some = function
  | Some x -> x
  | None -> failwith "cpu test: a traced signal was not found by name"
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
  (* One reset cycle, register operations, a load (0x8000_0000: [stall] and [rd] for one
     cycle while PC and IR hold), then a [stall_x] pulse. Only the fetch and stall timing
     is under test: [codebus] is driven freely here, where in the machine it is Mem[adr]. *)
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

(* [regmux] is the value written back. The flags are registered, so they show one cycle
   after the result they describe. *)
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
  (* MOV R1,#5; MOV R2,#3; ADD R3,R1,R2 (8); SUB R4,R2,R1 (-2: N and the borrow C set);
     two NOPs so the registered flags show *)
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

(* MUL R3,R1,R2 with 7 and 6. The multiplier holds [stall] for 33 cycles with PC and IR
   frozen; on the cycle it drops, the low word is written back and the high word lands in

   H. The run is too long to print whole, so the head and the tail are shown. *)
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
  (* head: the MUL in IR, [stall] up, PC held at 0x100 *)
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
  (* tail: [stall] drops, regmux = 42 (0x2A), H = 0, PC advances *)
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

(* A taken branch-and-link and a conditional branch not taken, two cycles each so that the
   PC register shows the outcome. *)
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
  (* BL +3 from 0x100: PC = 0x101 + 3 = 0x104, and regmux is the link, 0x101 << 2 = 0x404.
     Then BEQ +8 with Z = 0: PC falls through to 0x101. *)
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

(* A load and a store, two cycles each: the first drives the data address and the strobe
   with PC and IR held, the second is a bubble. *)
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
  (* load word R1,[R2] with R2 = 0x1000; store byte R1,[R2+2] with R1 = 0xAB, R2 = 0x2000:
     outbus carries 0xAB in lane 2 *)
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

(* The interrupt handshake, the one part of the core the oracle cannot check. STI enables;
   a one-cycle [irq] pulse becomes pending on its rising edge; the acknowledge sends PC to
   the vector (address 1), sets [int_md] and saves the flags and the return PC in SPC; RTI
   restores both and clears [int_md]. The run starts at PC 0x100 with C = 1, so the saved
   SPC, 0x800103, shows the flag (bit 23) beside the return PC. Every instruction driven
   is a never-taken branch: NOP 0xCF000000, STI 0xCF000021, RTI 0xCF000010. *)
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

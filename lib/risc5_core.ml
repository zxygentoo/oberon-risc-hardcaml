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
     no-reset registers: there is no clear port. [rst] (active low) reaches the datapath
     as ordinary logic (pcmux below), exactly as the RTL does it. 4.0 brings up the three
     fetch-timing registers; N/Z/C/OV/H join in 4.1-4.2, the interrupt state in 4.5.
     [pc]/[ir]/[stall] are named (--) so the waveform tests can watch them. *)
  let pc = Always.Variable.reg spec ~width:22 in
  let ir = Always.Variable.reg spec ~width:32 in
  let stall_l1 = Always.Variable.reg spec ~width:1 in
  let pc_v = pc.value -- "pc" in
  let ir_v = ir.value -- "ir" in
  let stall_l1_v = stall_l1.value in
  (* ── Instruction decode (RISC5.v:70-96) ── the four mode bits, and the two memory
     op-classes that gate the bus and the load/store stall; the remaining
     fields/op-classes are decoded as each later slice wires its ops. *)
  let p = select ir_v ~high:31 ~low:31 in
  let q = select ir_v ~high:30 ~low:30 in
  let u = select ir_v ~high:29 ~low:29 in
  let v = select ir_v ~high:28 ~low:28 in
  let ldr = p &: ~:q &: ~:u in
  (* RISC5.v:93 *)
  let str = p &: ~:q &: u in
  (* RISC5.v:94 *)
  (* ── Stall aggregation (RISC5.v:168-169) ── the multi-cycle unit stalls (M/D/FA/FM/FD)
     OR into [stall] in 4.2; for now it is the load/store stall and the external stall. *)
  let stall_l0 = ldr |: str &: ~:stall_l1_v in
  (* RISC5.v:168 *)
  let stall = (stall_l0 |: i.stall_x) -- "stall" in
  (* RISC5.v:169 (partial) *)
  (* ── Control unit: next PC (RISC5.v:138, 150-153) ── 4.0 keeps the reset/stall/step
     ladder; intAck, RTI, and the branch target layer in at 4.3 (branches) / 4.5 (ints). *)
  let nxpc = pc_v +:. 1 in
  (* RISC5.v:138 *)
  let start_adr = of_unsigned_int ~width:22 0x3F_F800 in
  (* RISC5.v:11, StartAdr *)
  let pcmux = mux2 ~:(i.rst_n) start_adr (mux2 stall pc_v nxpc) in
  (* ── Memory bus (RISC5.v:101-104) ── the control strobes are final; [adr]'s load/store
     data-address branch ([stallL0 ? B+off]) and [outbus]'s store data arrive with the
     register file in 4.4, so [adr] is the fetch address and [outbus] is 0 for now. *)
  let adr = pcmux @: zero 2 in
  (* RISC5.v:101 (fetch path) *)
  let rd = ldr &: ~:(i.stall_x) &: ~:stall_l1_v in
  (* RISC5.v:102 *)
  let wr = str &: ~:(i.stall_x) &: ~:stall_l1_v in
  (* RISC5.v:103 *)
  let ben = p &: ~:q &: v &: ~:(i.stall_x) &: ~:stall_l1_v in
  (* RISC5.v:104 *)
  let outbus = zero 32 in
  (* RISC5.v:132 — store data from reg A; 4.4 *)
  (* ── Sequential update — the one always block (RISC5.v:171-183) ── this list grows to
     all twelve registers as the slices land; today the three fetch-timing registers. *)
  Always.(
    compile
      [ pc <-- pcmux (* RISC5.v:172 *)
      ; ir <-- mux2 stall ir_v i.codebus (* RISC5.v:173 *)
      ; stall_l1 <-- mux2 i.stall_x stall_l1_v stall_l0 (* RISC5.v:174 *)
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

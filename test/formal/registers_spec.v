`timescale 1ns / 1ps
// Behavioral register-file SPEC — the Phase-8 formal reference for our Registers.
//
// Deliberately NOT Wirth's Registers.v. That original builds the triple-port file from 64
// duplicated, bit-sliced Xilinx RAM16X1D distributed-RAM primitives — a *synthesis idiom*
// (how you get a 3rd asynchronous read port out of 2-read-port LUT RAM), not observable
// behaviour. Its bit-sliced + duplicated state (1024 bits) is structurally incongruent with
// our single 16x32 array (512 bits): that defeats name-based flip-flop pairing (equiv_induct
// has nothing to match), and a memory miter is not inductive on outputs alone (an unread
// location can differ in an unreachable state). Empirically only a shallow bounded check is
// tractable there — see test/formal/README.
//
// So we prove our Hardcaml Registers equivalent to the behavioural CONTRACT it must meet:
// 16 words x 32 bits, three asynchronous reads, one synchronous write at rno0. That Wirth's
// RAM16X1D duplication implements this same contract is *his* synthesis concern (honoured by
// Vivado's distributed-RAM inference), not ours — exactly the AGENT.md §2/§3 "structure is
// not the spec" line, of which the register file is the canonical case.
module Registers_spec (
  input clk, wr,
  input [3:0] rno0, rno1, rno2,
  input [31:0] din,
  output [31:0] dout0, dout1, dout2);

reg [31:0] regfile [0:15];
integer i;
initial for (i = 0; i < 16; i = i + 1) regfile[i] = 0;  // RAM16X1D INIT = 0

assign dout0 = regfile[rno0];  // SPO @ rno0 (the write/single port)
assign dout1 = regfile[rno1];  // DPO @ rno1
assign dout2 = regfile[rno2];  // DPO @ rno2 (in the RTL, the duplicate block's read port)

always @(posedge clk) if (wr) regfile[rno0] <= din;
endmodule

`timescale 1ns / 1ps
// Black-box stubs for the 8 submodules RISC5.v instantiates — port-only, marked blackbox.
// The in-situ core proof (test_formal.ml `core`) reads these so BOTH RISC5.v (gold) and our
// emitted core (gate) reference the same opaque modules; yosys equiv_make then pairs/merges
// the matched instances and `cutpoint -blackbox` turns their outputs into shared free signals
// (assume-guarantee — each submodule is proven equivalent separately, §6). Headers match the
// modules' real .v exactly (and our Instantiation stubs in core_blackbox.ml).
(* blackbox *) module LeftShifter (input [31:0] x, output [31:0] y, input [4:0] sc);
endmodule
(* blackbox *) module RightShifter (input [31:0] x, output [31:0] y, input [4:0] sc, input md);
endmodule
(* blackbox *) module Multiplier (
  input clk, run, u, output stall, input [31:0] x, y, output [63:0] z);
endmodule
(* blackbox *) module Divider (
  input clk, run, u, output stall, input [31:0] x, y, output [31:0] quot, rem);
endmodule
(* blackbox *) module FPAdder (
  input clk, run, u, v, input [31:0] x, y, output stall, output [31:0] z);
endmodule
(* blackbox *) module FPMultiplier (
  input clk, run, input [31:0] x, y, output stall, output [31:0] z);
endmodule
(* blackbox *) module FPDivider (
  input clk, run, input [31:0] x, y, output stall, output [31:0] z);
endmodule
(* blackbox *) module Registers (
  input clk, wr, input [3:0] rno0, rno1, rno2, input [31:0] din,
  output [31:0] dout0, dout1, dout2);
endmodule

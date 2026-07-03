// Black-box stubs for the Xilinx primitives VID60.v instantiates to generate its pixel
// clock (`BUFG` + `DCM #(.CLKFX_MULTIPLY(13),.CLKFX_DIVIDE(5))`, i.e. pclk = clk*13/5).
// That clock *generation* is the Phase-7 board shim (the Nexys MMCM), dropped in our port
// (lib/video.ml takes pclk as an input). For the formal proof the driver deletes these cells
// and exposes pclk as a free clock input, matching our gate — so the stubs only need port
// shapes, no behaviour (AGENT.md §6, test/formal/README Tier 2).

(* blackbox *)
module BUFG(input I, output O);
endmodule

(* blackbox *)
module DCM #(parameter CLK_FEEDBACK = "NONE",
             parameter CLKFX_MULTIPLY = 13,
             parameter CLKFX_DIVIDE = 5)
  (input  CLKIN, CLKFB, RST, DSSEN, PSCLK, PSEN, PSINCDEC,
   output CLK0, CLK90, CLK180, CLK270, CLKDV, CLKFX, CLKFX180,
          CLK2X, CLK2X180, LOCKED, PSDONE,
   output [7:0] STATUS);
endmodule

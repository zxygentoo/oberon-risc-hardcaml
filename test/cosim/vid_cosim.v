// Cosim wrapper for VID60.v. The reference VID generates its 65 MHz pixel clock internally
// with a Xilinx DCM (x13/5 of clk) and buffers clk with a BUFG — primitives Verilator does
// not know. We (1) stub both, and (2) drive the two clocks from the harness: clk is VID's
// real input, while pclk is generated *inside* VID, so we `force` its internal net to this
// wrapper's pclk input. The harness toggles clk (period 13) and pclk (period 5) on a fine
// base tick — the 65:25 MHz ratio — matching the Hardcaml dumper's By_input_clocks model.
// VID60.v itself is byte-for-byte the pinned reference (test/rtl-sources.txt).

module BUFG (
    input  I,
    output O
);
  assign O = I;
endmodule

module DCM #(
    parameter CLK_FEEDBACK = "NONE",
    parameter CLKFX_MULTIPLY = 4,
    parameter CLKFX_DIVIDE = 1
) (
    input CLKIN,
    RST,
    DSSEN,
    PSCLK,
    PSEN,
    PSINCDEC,
    output CLK0,
    CLK90,
    CLK180,
    CLK270,
    CLKDV,
    CLKFX,
    CLKFX180,
    CLKFB,
    CLK2X,
    CLK2X180,
    LOCKED,
    PSDONE,
    output [7:0] STATUS
);
  // CLKFX (VID's pclk) is force-driven by the wrapper below; this stub only resolves the cell.
endmodule

module vid_cosim (
    input wire clk,
    pclk,
    inv,
    input wire [31:0] viddata,
    output wire req,
    output wire [17:0] vidadr,
    output wire hsync,
    vsync,
    output wire [5:0] RGB
);
  VID #(.RGBW(6)) dut (
      .clk(clk),
      .inv(inv),
      .viddata(viddata),
      .req(req),
      .vidadr(vidadr),
      .hsync(hsync),
      .vsync(vsync),
      .RGB(RGB)
  );
  // override the DCM-generated internal pixel clock with the harness's pclk
  initial force dut.pclk = pclk;
endmodule

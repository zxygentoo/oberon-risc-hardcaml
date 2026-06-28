// Cosim wrapper for MousePM.v. The reference mouse uses open-drain inout msclk/msdat
// (line = drive ? 0 : z); Verilator is 2-state with no z, so we split the bidirectional
// lines exactly like the Hardcaml port. The harness drives the resolved wire value into the
// DUT (force, overriding the DUT's own open-drain drive), and we XMR-read the DUT's pull-low
// intent (req for msclk, ~tx[0] for msdat) out as *_oe. MousePM.v itself is byte-for-byte
// the pinned reference (test/rtl-sources.txt).

module mouse_cosim (
    input  wire        clk,
    rst,
    input  wire        msclk_in,
    msdat_in,
    output wire        msclk_oe,
    msdat_oe,
    output wire [27:0] out
);
  MouseP dut (
      .clk(clk),
      .rst(rst),
      .msclk(),
      .msdat(),
      .out(out)
  );
  initial begin
    force dut.msclk = msclk_in;
    force dut.msdat = msdat_in;
  end
  assign msclk_oe = dut.req;
  assign msdat_oe = ~dut.tx[0];
endmodule

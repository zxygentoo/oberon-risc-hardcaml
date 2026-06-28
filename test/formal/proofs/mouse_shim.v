// Open-drain shims for the Mouse formal proof (AGENT.md §6, README Tier 2).
//
// MousePM.v's `MouseP` has two bidirectional open-drain pins:
//   assign msclk = req    ? 1'b0 : 1'bz;   // pull low, else release (external pull-up -> 1)
//   assign msdat = ~tx[0] ? 1'b0 : 1'bz;
// and reads them back (into `filter` / `rx`). Hardcaml has no inout/tristate, so our port
// (lib/mouse.ml) SPLITS each pin into a drive-low output (`*_oe`) plus the resolved-value
// input — "the open-drain wired-AND lives in the pad" (the lib comment).
//
// To prove the two equivalent, wrap BOTH into one explicit interface and compare the
// observable *resolved line* (not the internal drive-enable, which is only observable
// through the line). The external device's contribution is a FREE primary input
// `*_ext` (1 = released / pulled up, 0 = device pulls low) fed identically to both sides
// — this is essential: without a free external read, yosys ties the inout read to 0 and
// the whole FSM degenerates to constants (a vacuous proof).
//
// Resolution (open-drain wire-AND with pull-up): line = oe ? 0 : ext.
//   - ours side: pure logic, since `*_oe` is an explicit output.
//   - gold side: MouseP drives its inout as `oe ? 0 : 1'bz`; the external driver below adds
//     `ext ? 1'bz : 1'b0`. The driver's script resolves these with `tribuf -formal` (convert
//     ALL tristate to logic, incl. the inout-port drivers) + `chformal -remove` (drop tribuf's
//     "no two drivers" assertion — open-drain legally has multiple low drivers) + `setundef
//     -one` (tie the both-released float to 1, the pad's pull-up). The result is exactly
//     `line = oe ? 0 : ext`, matching the ours side.

module mouse_gold_shim(
  input  wire clk, rst,
  input  wire msclk_ext, msdat_ext,    // free external open-drain driver (1 = released)
  output wire msclk_line, msdat_line,  // resolved open-drain value (the observable)
  output wire [27:0] out);
  MouseP g(.clk(clk), .rst(rst), .msclk(msclk_line), .msdat(msdat_line), .out(out));
  assign msclk_line = msclk_ext ? 1'bz : 1'b0;
  assign msdat_line = msdat_ext ? 1'bz : 1'b0;
endmodule

module mouse_ours_shim(
  input  wire clk, rst,
  input  wire msclk_ext, msdat_ext,
  output wire msclk_line, msdat_line,
  output wire [27:0] out);
  wire oe_c, oe_d;
  mouse_ours g(.clk(clk), .rst(rst), .msclk(msclk_line), .msdat(msdat_line),
               .msclk_oe(oe_c), .msdat_oe(oe_d), .out(out));
  assign msclk_line = oe_c ? 1'b0 : msclk_ext;   // open-drain resolve, pure logic
  assign msdat_line = oe_d ? 1'b0 : msdat_ext;
endmodule

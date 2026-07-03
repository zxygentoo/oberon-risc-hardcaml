// CDC fetch-invariant proof for VID's pulse synchroniser (AGENT.md §6, README Tier 2).
//
// The equiv proof (check_vid) proves VID's raster + pixel datapath ≡ VID60.v but CUTS the
// fetch CDC (our toggle synchroniser vs the RTL async-set req1 — a deliberate departure, not
// a cycle-equivalence). This proof closes that gap differently: it proves the synchroniser's
// *protocol* — every req0 yields exactly one req, no loss, no duplication — for ALL
// clk/pclk phase interleavings, which the (single-phase) Cyclesim invariant test can't.
//
// It wraps the REAL emitted synchroniser (pulse_sync_ours = lib/video.ml's pulse_sync, the DUT)
// with a req0 generator + a clock-fairness assumption + a balance monitor, and is discharged
// by yosys-smtbmc (the engine SymbiYosys wraps) over z3: clk2fflogic models the two clocks,
// BMC explores every fair phase relationship to the configured depth. See
// Yosys_equiv.check_bmc / run_vid_invariant.

module vid_invariant(input clk, input pclk);
  // req0 generator: a clean 1-pclk pulse every K pclk, like VID's hcnt[4:0]==0. K=8 is a
  // representative *stress* spacing — at the fair clock ratio (≤2:1) that is ≥4 clk, just
  // above the 3-deep synchroniser; the real vid's 32 px (≈12 clk) has more margin, so a pass
  // here covers it a fortiori. The property is independent of K once K > the pipeline depth.
  localparam K = 8;
  reg [3:0] hc = 0;
  always @(posedge pclk) hc <= (hc == K-1) ? 0 : hc + 1;
  wire req0 = (hc == 0);

  // the DUT: the real emitted toggle pulse synchroniser
  wire req;
  pulse_sync_ours dut(.clk(clk), .pclk(pclk), .req0(req0), .req(req));

  // clock fairness: real clocks keep ticking — neither clk nor pclk stalls. Without this
  // the solver could freeze clk while pclk runs (req0 piling up with no req), an unphysical
  // counterexample to no-loss.
  reg clk_q = 0, pclk_q = 0;
  reg [1:0] clk_st = 0, pclk_st = 0;
  always @($global_clock) begin
    clk_q <= clk; pclk_q <= pclk;
    clk_st  <= (clk  != clk_q)  ? 0 : clk_st  + 1;
    pclk_st <= (pclk != pclk_q) ? 0 : pclk_st + 1;
  end
  always @(*) begin assume (clk_st <= 1); assume (pclk_st <= 1); end

  // balance monitor: +1 each req0 pulse (entering), -1 each req pulse (exiting).
  reg req0_q = 0, req_q = 0;
  reg [3:0] bal = 0;
  wire req0_rise = req0 & ~req0_q;
  wire req_rise  = req  & ~req_q;
  always @($global_clock) begin
    req0_q <= req0; req_q <= req;
    bal <= bal + req0_rise - req_rise;
  end
  always @(*) begin
    assert (!(req_rise && bal == 0));  // no-spurious / no-dup: req only with a req0 outstanding
    assert (bal <= 2);                 // no-loss: outstanding bounded ⇒ no request piles up lost
  end
endmodule

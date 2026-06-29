`timescale 1ns / 1ps
`default_nettype none
//
// Phase 7 board top for the original Digilent Nexys 4 (XC7A100T, Cellular-RAM).
// Hand-written vendor wrapper around the Hardcaml-generated `soc_board`
// (boards/_generated/nexys-4/soc_board.v): clock generation (MMCM 100->25/65 MHz), a
// power-on reset, and the IOBUFs / pin mapping the synthesizable design can't express.
// See boards/nexys-4/README.md.
//
// Mouse bring-up build: the single PS/2 port (presented by the board's USB-HID PIC) is
// wired to the MOUSE — Oberon is mouse-driven, so the mouse comes first. The keyboard
// stays idled until the 2nd-port PS/2 Pmod lands. The Mouse module is develop's faithful,
// cosim/formal-proven port of MousePM.v (no scratch workarounds). LD9-14 diagnose the
// bring-up (see the status-LED block at the bottom).
//
module nexys4_top (
  input  wire        CLK100MHZ,     // E3, 100 MHz
  input  wire        btnCpuReset,   // C12, active-low reset button

  input  wire [7:0]  sw,            // SW0..7 (logical/active-high; sw[7] = video invert)
  input  wire        btnU,          // nav buttons -> soc_board.btn[3:0]
  input  wire        btnD,
  input  wire        btnL,
  input  wire        btnR,
  output wire [15:0] led,           // LD0..7 = Oberon LEDs; LD8 heartbeat, LD9-14 mouse, LD15 MMCM lock

  input  wire        RsRx,          // C4  USB-UART, host->FPGA
  output wire        RsTx,          // D4  USB-UART, FPGA->host

  output wire [3:0]  vgaRed,        // VGA 4-4-4; we drive 1 bpp mono onto all 12
  output wire [3:0]  vgaGreen,
  output wire [3:0]  vgaBlue,
  output wire        Hsync,         // B11
  output wire        Vsync,         // B12

  inout  wire        PS2Clk,        // F4  PS/2 (wired to the MOUSE — open-drain, bidirectional)
  inout  wire        PS2Data,       // B2

  output wire        sd_sck,        // B1  microSD in SPI mode
  output wire        sd_cmd,        // C1  (MOSI)
  input  wire        sd_dat0,       // C2  (MISO)
  output wire        sd_dat3,       // D2  (CS, active-low)
  output wire        sd_reset,      // E2

  // Cellular RAM (async SRAM interface)
  output wire [22:0] MemAdr,
  inout  wire [15:0] MemDB,
  output wire        RamOEn,
  output wire        RamWEn,
  output wire        RamCEn,
  output wire        RamLBn,
  output wire        RamUBn,
  output wire        RamCRE,
  output wire        RamADVn,
  output wire        RamCLK
);

  // ── Clocking: one MMCM, 100 MHz -> 25 MHz (system) + 65 MHz (pixel) ──────────────
  // VCO = 100 * 6.5 = 650 MHz; 650/26 = 25 MHz, 650/10 = 65 MHz (1024x768@60 pixel clk).
  wire clk25, clk65, clkfb, clkfb_bufg, mmcm_locked;
  wire clk25_raw, clk65_raw;

  MMCME2_BASE #(
    .CLKIN1_PERIOD   (10.000),   // 100 MHz
    .DIVCLK_DIVIDE   (1),
    .CLKFBOUT_MULT_F (6.500),    // VCO 650 MHz
    .CLKOUT0_DIVIDE_F(26.000),   // 25 MHz
    .CLKOUT1_DIVIDE  (10),       // 65 MHz
    .STARTUP_WAIT    ("FALSE")
  ) mmcm (
    .CLKIN1   (CLK100MHZ),
    .CLKFBIN  (clkfb_bufg),
    .CLKFBOUT (clkfb),
    .CLKFBOUTB(),
    .CLKOUT0  (clk25_raw),
    .CLKOUT0B (),
    .CLKOUT1  (clk65_raw),
    .CLKOUT1B (),
    .CLKOUT2  (), .CLKOUT2B(),
    .CLKOUT3  (), .CLKOUT3B(),
    .CLKOUT4  (),
    .CLKOUT5  (),
    .CLKOUT6  (),
    .LOCKED   (mmcm_locked),
    .PWRDWN   (1'b0),
    .RST      (1'b0)
  );

  BUFG bufg_fb (.I(clkfb),     .O(clkfb_bufg));
  BUFG bufg_25 (.I(clk25_raw), .O(clk25));
  BUFG bufg_65 (.I(clk65_raw), .O(clk65));

  // ── Power-on / button reset (active-low rst_n to the SoC) ────────────────────────
  // Held low until the MMCM locks and a counter elapses (covers PSRAM power-up), and
  // whenever the reset button is pressed (btnCpuReset is active-low).
  reg  [15:0] por_cnt = 16'hFFFF;
  wire        por_done = (por_cnt == 16'd0);
  always @(posedge clk25) begin
    if (!mmcm_locked)   por_cnt <= 16'hFFFF;
    else if (!por_done) por_cnt <= por_cnt - 16'd1;
  end
  wire rst_n = mmcm_locked & por_done & btnCpuReset;

  // ── Cellular RAM bidirectional data bus (16 IOBUFs) ──────────────────────────────
  wire [15:0] mem_dq_o, mem_dq_i;
  wire        mem_dq_t;
  genvar gi;
  generate
    for (gi = 0; gi < 16; gi = gi + 1) begin : memdb_iob
      IOBUF iob (.I(mem_dq_o[gi]), .O(mem_dq_i[gi]), .IO(MemDB[gi]), .T(mem_dq_t));
    end
  endgenerate

  // async-SRAM mode tie-offs (no burst/sync, no config register)
  assign RamCLK  = 1'b0;
  assign RamADVn = 1'b0;   // address always valid (async)
  assign RamCRE  = 1'b0;   // memory array, not config register

  // ── PS/2 mouse, open-drain bidirectional (single PS/2 port via the USB-HID PIC) ───
  // Drive the line low when the SoC requests it (msX_oe=1), else release to hi-Z — the
  // XDC pullup + the device pullup hold it high. The PIC presents the USB mouse as a PS/2
  // device on these pins; the Mouse module sends enable / sample-rate init by pulling the
  // lines low (request-to-send), then receives the device's report stream.
  wire        msclk_oe, msdat_oe;   // mouse open-drain pull-low requests (from the SoC)
  wire        ps2c_in, ps2d_in;     // resolved PS/2 lines into the mouse module
  wire [27:0] mouse_dbg;            // {run, btns[2:0], 2'b0, y[9:0], 2'b0, x[9:0]} for the LEDs
  IOBUF ps2c_iobuf (.I(1'b0), .O(ps2c_in), .IO(PS2Clk),  .T(~msclk_oe));
  IOBUF ps2d_iobuf (.I(1'b0), .O(ps2d_in), .IO(PS2Data), .T(~msdat_oe));

  // ── The Hardcaml SoC ─────────────────────────────────────────────────────────────
  wire [5:0] rgb;
  wire       hsync, vsync;

  soc_board soc (
    .clock    (clk25),
    .pclk     (clk65),
    .rst_n    (rst_n),

    // SD-card SPI master
    .miso     (sd_dat0),
    .mosi     (sd_cmd),
    .sclk     (sd_sck),
    .sd_cs    (sd_dat3),

    // UART
    .rxd      (RsRx),
    .txd      (RsTx),

    // buttons / switches (active-high; word-1 read)
    .btn      ({btnU, btnD, btnL, btnR}),
    .sw       (sw),

    // GPIO — idled (not wired to a Pmod in this build)
    .gpio_in  (8'b0),
    .gpio_out (),
    .gpio_oe  (),

    // PS/2 keyboard — idled (the single PS/2 port is given to the mouse; the keyboard
    // moves to the 2nd-port PS/2 Pmod once it arrives)
    .ps2c     (1'b1),
    .ps2d     (1'b1),

    // PS/2 mouse — the single PS/2 port, open-drain bidirectional via the IOBUFs above
    .msclk    (ps2c_in),
    .msdat    (ps2d_in),
    .msclk_oe (msclk_oe),
    .msdat_oe (msdat_oe),
    .mouse_dbg(mouse_dbg),

    // LEDs / video
    .leds     (led[7:0]),
    .hsync    (hsync),
    .vsync    (vsync),
    .rgb      (rgb),

    // Cellular RAM controller pins
    .mem_dq_i (mem_dq_i),
    .mem_adr  (MemAdr),
    .mem_dq_o (mem_dq_o),
    .mem_dq_t (mem_dq_t),
    .ram_ce_n (RamCEn),
    .ram_oe_n (RamOEn),
    .ram_we_n (RamWEn),
    .ram_ub_n (RamUBn),
    .ram_lb_n (RamLBn)
  );

  // ── VGA: 1 bpp mono replicated across the 12-bit DAC ─────────────────────────────
  wire pixel = rgb[0];
  assign vgaRed   = {4{pixel}};
  assign vgaGreen = {4{pixel}};
  assign vgaBlue  = {4{pixel}};
  assign Hsync    = hsync;   // soc_board sync outputs are already active-low (VGA -h/-v)
  assign Vsync    = vsync;

  // ── microSD housekeeping ─────────────────────────────────────────────────────────
  assign sd_reset = 1'b0;    // hold the card out of reset / powered (verify polarity on HW)

  // ── Status / PS/2-mouse-diagnostic LEDs (upper bank) ─────────────────────────────
  // LD8 = 25 MHz heartbeat, LD15 = MMCM locked. LD9-14 diagnose the mouse bring-up.
  reg [24:0] heartbeat = 25'd0;
  always @(posedge clk25) heartbeat <= heartbeat + 25'd1;

  localparam [24:0] HOLD = 25'd2_500_000;   // ~0.1 s persistence at 25 MHz

  // Decoded mouse state from the SoC debug word {run, btns[2:0], 2'b0, y[9:0], 2'b0, x[9:0]}.
  wire        ms_run  = mouse_dbg[27];
  wire [2:0]  ms_btns = mouse_dbg[26:24];
  wire [9:0]  ms_y    = mouse_dbg[21:12];
  wire [9:0]  ms_x    = mouse_dbg[9:0];

  // Sticky "has the module EVER decoded movement / a button?" latches — the decisive
  // bring-up signal. Move the mouse, then read them: x/y_ever lit => the report decode
  // works (so a dead cursor is Oberon-side); dark => the decode/done path is failing.
  // Cleared by reset (btnCpuReset / POR).
  reg x_ever = 1'b0, y_ever = 1'b0, btns_ever = 1'b0;
  // Retriggerable activity one-shots (on = happening now, off ~0.1 s after it stops).
  reg [24:0] hold_ps2c = 0, hold_host = 0;
  reg        ps2c_d = 0;
  always @(posedge clk25) begin
    ps2c_d <= ps2c_in;
    if (!rst_n) begin
      x_ever <= 1'b0; y_ever <= 1'b0; btns_ever <= 1'b0;
    end else begin
      if (ms_x != 10'd0) x_ever    <= 1'b1;
      if (ms_y != 10'd0) y_ever    <= 1'b1;
      if (|ms_btns)      btns_ever <= 1'b1;
    end
    hold_ps2c <= (ps2c_d ^ ps2c_in)    ? HOLD : (hold_ps2c != 0 ? hold_ps2c - 25'd1 : 25'd0);
    hold_host <= (msclk_oe | msdat_oe) ? HOLD : (hold_host != 0 ? hold_host - 25'd1 : 25'd0);
  end

  assign led[8]  = heartbeat[24];      // ~0.75 Hz blink: the 25 MHz clock is alive
  assign led[9]  = ms_run;             // mouse init completed (run=1, now streaming reports)
  assign led[10] = x_ever;             // module's X accumulated away from 0 (X decode works)
  assign led[11] = y_ever;             // module's Y accumulated away from 0 (Y decode works)
  assign led[12] = btns_ever;          // a mouse button was decoded as pressed
  assign led[13] = (hold_ps2c != 0);   // PS/2 clock edges (device clocking packets to us)
  assign led[14] = (hold_host != 0);   // mouse module pulling lines low (sending commands)
  assign led[15] = mmcm_locked;

endmodule

`default_nettype wire

// Behavioral RAM16X1D for the core co-sim. Registers.v (the triple-port register file)
// infers the Xilinx RAM16X1D distributed-RAM primitive, which Verilator does not know — so
// we provide its exact semantics here, the same way vid_cosim.v stubs DCM/BUFG. A 16x1
// dual-port distributed RAM: asynchronous (combinational) reads on both ports, synchronous
// write on WCLK when WE. SPO reads the write-port address A[3:0]; DPO reads the read-only
// port address DPRA[3:0]. INIT seeds the contents (Registers.v passes 16'h0000, so the
// regfile powers up all-zero — matching our Hardcaml regfile, so boot states align).
module RAM16X1D #(
    parameter [15:0] INIT = 16'h0000
) (
    output DPO,
    output SPO,
    input  D,
    input  WCLK,
    input  WE,
    input  A0,
    A1,
    A2,
    A3,
    input  DPRA0,
    DPRA1,
    DPRA2,
    DPRA3
);
  reg [15:0] mem = INIT;
  wire [3:0] wa = {A3, A2, A1, A0};
  wire [3:0] ra = {DPRA3, DPRA2, DPRA1, DPRA0};
  assign SPO = mem[wa];
  assign DPO = mem[ra];
  always @(posedge WCLK) if (WE) mem[wa] <= D;
endmodule

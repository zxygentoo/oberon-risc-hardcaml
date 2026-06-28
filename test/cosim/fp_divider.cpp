// RTL-fidelity co-sim for Fp_divider: drive the reference test/_po/verilog/src/FPDivider.v through
// Verilator on each stimulus dumped by test/cosim/fp_dump, and assert RTL z == port z AND RTL
// stall-length == port stall-length. Exit 0 iff bit-exact AND cycle-exact to FPDivider.v.
//   usage:  cosim <port_dump_path>          (lines: "x y port_z port_cycles")
// The open -> run -> drain -> compare loop is shared (cosim.h's run_drain_cosim); this file
// just names the unit and picks the modifier-free parser. Driven by cosim_run; see README.md.

#include "VFPDivider.h"
#include "cosim.h"

int main(int argc, char** argv) {
  FILE* f = cosim_open(argc, argv);
  if (!f) return 2;
  VFPDivider dut;
  return run_drain_cosim(
    { "fp_divider", "Fp_divider", "FPDivider.v" }, &dut, f, parse_xy<VFPDivider>);
}

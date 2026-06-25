// RTL-fidelity co-sim for Fp_multiplier: drive the reference _po/verilog/src/FPMultiplier.v
// through Verilator on each stimulus dumped by test/cosim/dump_fp, and assert RTL z == port z AND
// RTL stall-length == port stall-length. Exit 0 iff bit-exact AND cycle-exact to FPMultiplier.v.
//   usage:  cosim <port_dump_path>          (lines: "x y port_z port_cycles")
// The open -> run -> drain -> compare loop is shared (cosim.h's run_drain_cosim); this file
// just names the unit and picks the modifier-free parser. Driven by run.sh; see README.md.

#include "VFPMultiplier.h"
#include "cosim.h"

int main(int argc, char** argv) {
  FILE* f = cosim_open(argc, argv);
  if (!f) return 2;
  VFPMultiplier dut;
  return run_drain_cosim(
    { "fp_multiplier", "Fp_multiplier", "FPMultiplier.v" }, &dut, f, parse_xy<VFPMultiplier>);
}

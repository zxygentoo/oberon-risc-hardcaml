// RTL-fidelity co-sim for Fp_adder: drive the reference _po/verilog/src/FPAdder.v through
// Verilator on each stimulus dumped by test/cosim/dump_fp, and assert RTL z == port z AND RTL
// stall-length == port stall-length. Exit 0 iff bit-exact AND cycle-exact to FPAdder.v.
//   usage:  cosim <port_dump_path>          (lines: "x y u v port_z port_cycles")
// The whole open -> run -> drain -> compare loop is shared (cosim.h's run_drain_cosim); this
// file just names the unit and picks the adder's parser (it carries the u/v modifiers). Driven
// by test/cosim/run.sh; see test/cosim/README.md.

#include "VFPAdder.h"
#include "cosim.h"

int main(int argc, char** argv) {
  FILE* f = cosim_open(argc, argv);
  if (!f) return 2;
  VFPAdder dut;
  return run_drain_cosim({ "fp_adder", "Fp_adder", "FPAdder.v" }, &dut, f, parse_xyuv<VFPAdder>);
}

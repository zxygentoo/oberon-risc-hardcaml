// RTL-fidelity co-sim for Fp_adder: drive the reference _po/verilog/src/FPAdder.v through
// Verilator on each stimulus dumped by test/cosim/dump_fp, and assert RTL z == port z AND
// RTL stall-length == port stall-length. Exit 0 iff the Hardcaml port is bit-exact AND
// cycle-exact to FPAdder.v over the whole stimulus set.
//   usage:  cosim <port_dump_path>          (lines: "x y u v port_z port_cycles")
// The tick + run->drain->count protocol is shared via fp_cosim.h; this file is just the
// adder's stimulus loop (it carries the u/v modifiers). Driven by test/cosim/run.sh.

#include "VFPAdder.h"
#include "fp_cosim.h"
#include <cstdio>

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  if (argc < 2) {
    fprintf(stderr, "usage: %s <port_dump_path>\n", argv[0]);
    return 2;
  }
  FILE* f = fopen(argv[1], "r");
  if (!f) {
    fprintf(stderr, "cannot open %s\n", argv[1]);
    return 2;
  }
  VFPAdder* dut = new VFPAdder;

  unsigned int x, y, pz;
  int u, v, pcyc;
  long n = 0, mismatch = 0, cyc_mismatch = 0;
  while (fscanf(f, "%x %x %d %d %x %d", &x, &y, &u, &v, &pz, &pcyc) == 6) {
    dut->u = u;
    dut->v = v;
    dut->x = x;
    dut->y = y;
    int rcyc = 0;
    uint32_t rz = drain(dut, &rcyc);
    n++;
    if (rz != (uint32_t)pz) {
      mismatch++;
      if (mismatch <= 20)
        printf("MISMATCH x=%08X y=%08X u=%d v=%d: RTL=%08X PORT=%08X\n", x, y, u, v, rz, pz);
    }
    if (rcyc != pcyc) {
      cyc_mismatch++;
      if (cyc_mismatch <= 20)
        printf("CYCLE-MISMATCH x=%08X y=%08X u=%d v=%d: RTL=%dcy PORT=%dcy\n", x, y, u, v, rcyc,
               pcyc);
    }
  }
  fclose(f);
  printf("fp_adder co-sim: %ld stimuli, %ld value-mismatch, %ld cycle-mismatch\n", n, mismatch,
         cyc_mismatch);
  if (mismatch == 0 && cyc_mismatch == 0)
    printf("==> Hardcaml Fp_adder is bit-exact AND cycle-exact to FPAdder.v.\n");
  delete dut;
  return (mismatch == 0 && cyc_mismatch == 0) ? 0 : 1;
}

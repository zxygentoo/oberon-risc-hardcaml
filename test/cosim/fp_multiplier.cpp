// RTL-fidelity co-sim for Fp_multiplier: drive the reference _po/verilog/src/FPMultiplier.v
// through Verilator on each stimulus dumped by test/cosim/dump_fp, and assert RTL z == port z
// AND RTL stall-length == port stall-length. Exit 0 iff the Hardcaml port is bit-exact AND
// cycle-exact to FPMultiplier.v over the set.
//   usage:  cosim <port_dump_path>          (lines: "x y port_z port_cycles")
// The tick + run->drain->count protocol is shared via fp_cosim.h; this file is just the
// multiplier's stimulus loop. Driven by test/cosim/run.sh; see test/cosim/README.md.

#include "VFPMultiplier.h"
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
  VFPMultiplier* dut = new VFPMultiplier;

  unsigned int x, y, pz;
  int pcyc;
  long n = 0, mismatch = 0, cyc_mismatch = 0;
  while (fscanf(f, "%x %x %x %d", &x, &y, &pz, &pcyc) == 4) {
    dut->x = x;
    dut->y = y;
    int rcyc = 0;
    uint32_t rz = drain(dut, &rcyc);
    n++;
    if (rz != (uint32_t)pz) {
      mismatch++;
      if (mismatch <= 20)
        printf("MISMATCH x=%08X y=%08X: RTL=%08X PORT=%08X\n", x, y, rz, pz);
    }
    if (rcyc != pcyc) {
      cyc_mismatch++;
      if (cyc_mismatch <= 20)
        printf("CYCLE-MISMATCH x=%08X y=%08X: RTL=%dcy PORT=%dcy\n", x, y, rcyc, pcyc);
    }
  }
  fclose(f);
  printf("fp_multiplier co-sim: %ld stimuli, %ld value-mismatch, %ld cycle-mismatch\n", n,
         mismatch, cyc_mismatch);
  if (mismatch == 0 && cyc_mismatch == 0)
    printf("==> Hardcaml Fp_multiplier is bit-exact AND cycle-exact to FPMultiplier.v.\n");
  delete dut;
  return (mismatch == 0 && cyc_mismatch == 0) ? 0 : 1;
}

// RTL-fidelity co-sim for Fp_multiplier: drive the reference _po/verilog/src/FPMultiplier.v
// through Verilator on each stimulus dumped by test/cosim/dump_fp, and assert RTL z == port z
// AND RTL stall-length == port stall-length. Exit 0 iff the Hardcaml port is bit-exact AND
// cycle-exact to FPMultiplier.v over the set.
//   usage:  cosim <port_dump_path>          (lines: "x y port_z port_cycles")
// Driven by test/cosim/run.sh; see test/cosim/README.md.

#include "VFPMultiplier.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>

static VFPMultiplier* dut;

static void tick() {
  dut->clk = 0;
  dut->eval();
  dut->clk = 1;
  dut->eval();
}

// hold inputs, run, drain until stall drops (S 0->25), read z, release run for one cycle.
// *cycles = clock cycles with run asserted until stall drops (the stall length), counted
// identically to dump_fp's port-side drive so the two are directly comparable.
static uint32_t run_op(uint32_t x, uint32_t y, int* cycles) {
  dut->x = x;
  dut->y = y;
  dut->run = 1;
  tick();
  int c = 1;
  while (dut->stall && c < 40) {
    tick();
    c++;
  }
  uint32_t z = dut->z;
  dut->run = 0;
  tick();
  *cycles = c;
  return z;
}

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
  dut = new VFPMultiplier;

  unsigned int x, y, pz;
  int pcyc;
  long n = 0, mismatch = 0, cyc_mismatch = 0;
  while (fscanf(f, "%x %x %x %d", &x, &y, &pz, &pcyc) == 4) {
    int rcyc = 0;
    uint32_t rz = run_op(x, y, &rcyc);
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

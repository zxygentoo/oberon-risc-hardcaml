// RTL-fidelity co-sim for Fp_multiplier: drive the reference _po/verilog/src/FPMultiplier.v
// through Verilator on each stimulus dumped by test/cosim/dump_fp, and assert
// RTL z == port z. Exit 0 iff the Hardcaml port is bit-exact to FPMultiplier.v over the set.
//   usage:  cosim <port_dump_path>          (lines: "x y port_z")
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

// hold inputs, run, drain until stall drops (S 0->25), read z, release run for one cycle
static uint32_t run_op(uint32_t x, uint32_t y) {
  dut->x = x;
  dut->y = y;
  dut->run = 1;
  tick();
  int safety = 0;
  while (dut->stall && safety < 40) {
    tick();
    safety++;
  }
  uint32_t z = dut->z;
  dut->run = 0;
  tick();
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
  long n = 0, mismatch = 0;
  while (fscanf(f, "%x %x %x", &x, &y, &pz) == 3) {
    uint32_t rz = run_op(x, y);
    n++;
    if (rz != (uint32_t)pz) {
      mismatch++;
      if (mismatch <= 20)
        printf("MISMATCH x=%08X y=%08X: RTL=%08X PORT=%08X\n", x, y, rz, pz);
    }
  }
  fclose(f);
  printf("fp_multiplier co-sim: %ld stimuli, %ld mismatch\n", n, mismatch);
  if (mismatch == 0) printf("==> Hardcaml Fp_multiplier is bit-exact to FPMultiplier.v.\n");
  delete dut;
  return mismatch == 0 ? 0 : 1;
}

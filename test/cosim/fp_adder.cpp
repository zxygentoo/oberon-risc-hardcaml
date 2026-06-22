// RTL-fidelity co-sim for Fp_adder: drive the reference _po/verilog/src/FPAdder.v through
// Verilator on each stimulus dumped by test/cosim/dump_fp, and assert RTL z == port z.
// Exit 0 iff the Hardcaml port is bit-exact to FPAdder.v over the whole stimulus set.
//   usage:  cosim <port_dump_path>          (lines: "x y u v port_z")
// Driven by test/cosim/run.sh; see test/cosim/README.md.

#include "VFPAdder.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>

static VFPAdder* dut;

static void tick() {
  dut->clk = 0;
  dut->eval();
  dut->clk = 1;
  dut->eval();
}

// hold inputs, run, drain until stall drops (State 0->3), read z, release run for one cycle
static uint32_t run_op(uint32_t x, uint32_t y, int u, int v) {
  dut->u = u;
  dut->v = v;
  dut->x = x;
  dut->y = y;
  dut->run = 1;
  tick();
  int safety = 0;
  while (dut->stall && safety < 20) {
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
  dut = new VFPAdder;

  unsigned int x, y, pz;
  int u, v;
  long n = 0, mismatch = 0;
  while (fscanf(f, "%x %x %d %d %x", &x, &y, &u, &v, &pz) == 5) {
    uint32_t rz = run_op(x, y, u, v);
    n++;
    if (rz != (uint32_t)pz) {
      mismatch++;
      if (mismatch <= 20)
        printf("MISMATCH x=%08X y=%08X u=%d v=%d: RTL=%08X PORT=%08X\n", x, y, u, v, rz, pz);
    }
  }
  fclose(f);
  printf("fp_adder co-sim: %ld stimuli, %ld mismatch\n", n, mismatch);
  if (mismatch == 0) printf("==> Hardcaml Fp_adder is bit-exact to FPAdder.v.\n");
  delete dut;
  return mismatch == 0 ? 0 : 1;
}

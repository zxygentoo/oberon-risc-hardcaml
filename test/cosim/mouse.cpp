// RTL-fidelity co-sim for Mouse: replay the per-cycle trace dumped by test/cosim/dump_mouse
// through the reference test/_po/verilog/src/MousePM.v (wrapped by mouse_cosim.v) under Verilator,
// and assert — every cycle — that the RTL's (msclk_oe, msdat_oe, out) == the Hardcaml port's.
// Exit 0 iff the port is bit- and cycle-exact to MousePM.v over the whole stimulus.
//   usage:  cosim <port_dump_path>   (lines: "rstn dmc dmd mco mdo out7hex")
//
// MousePM.v's msclk/msdat are open-drain inout; the wrapper forces the resolved wire value in
// and XMR-exports the DUT's pull-low (req, ~tx[0]) as *_oe. Here we resolve the open-drain the
// same way the dumper did: wire = ~(this DUT's *_oe | the recorded device pull-low). We read
// the RTL's *_oe BEFORE the edge (the dumper resolved against the port's pre-cycle oe too), so
// the two are phase-aligned; a behavioural divergence surfaces as an output mismatch. Reuses
// cosim.h's tick()/cosim_open().

#include "Vmouse_cosim.h"
#include "cosim.h" // tick(), cosim_open()
#include <cstdio>

int main(int argc, char** argv) {
  FILE* f = cosim_open(argc, argv);
  if (!f) return 2;
  Vmouse_cosim* dut = new Vmouse_cosim;

  long n = 0, mismatch = 0;
  int rstn, dmc, dmd, mco, mdo;
  unsigned out;

  while (fscanf(f, "%d %d %d %d %d %x", &rstn, &dmc, &dmd, &mco, &mdo, &out) == 6) {
    dut->rst = rstn;
    // resolve the open-drain with the RTL's current (pre-edge) pull-low + the device's drive
    dut->msclk_in = !(dut->msclk_oe || dmc);
    dut->msdat_in = !(dut->msdat_oe || dmd);
    tick(dut);
    if (dut->msclk_oe != mco || dut->msdat_oe != mdo || (unsigned)dut->out != out) {
      mismatch++;
      if (mismatch <= 20)
        printf("MISMATCH cyc=%ld: RTL mco=%d mdo=%d out=%07x | PORT mco=%d mdo=%d out=%07x\n", n,
               dut->msclk_oe, dut->msdat_oe, (unsigned)dut->out, mco, mdo, out);
    }
    n++;
  }
  fclose(f);
  printf("mouse co-sim: %ld cycles, %ld mismatch\n", n, mismatch);
  if (mismatch == 0) printf("==> Hardcaml Mouse is bit-exact AND cycle-exact to MousePM.v.\n");
  delete dut;
  return mismatch == 0 ? 0 : 1;
}

// RTL-fidelity co-sim for Ps2: replay each frame dumped by test/cosim/dump_ps2 through the
// reference test/_po/verilog/src/PS2.v under Verilator, asserting cycle-by-cycle that RTL rdy ==
// port's, plus RTL data == the recovered byte whenever rdy is high. Exit 0 iff bit- and
// cycle-exact to PS2.v.   usage:  cosim <port_dump_path>     (lines: "data hextrace")
//
// PS/2 is input-driven (the keyboard clocks us), so this is a fixed-length trace replay. shift
// is ps2c-derived (Q1 & ~Q0) and trivially identical, so it isn't checked. The reset/loop/stats
// boilerplate is shared (run_serial_cosim in cosim.h); this file is just reset + replay.

#include "VPS2.h"
#include "cosim.h" // run_serial_cosim(), hexval(), tick(), cosim_open()
#include <cstdio>
#include <cstring>

static void reset_ps2(VPS2* dut) {
  // rst active-low, synchronous; ps2c/ps2d idle high. Then frames run back-to-back.
  dut->rst = 0;
  dut->PS2C = 1;
  dut->PS2D = 1;
  dut->done = 0;
  tick(dut);
  dut->rst = 1;
  tick(dut);
}

// each cycle drive (done, ps2c, ps2d) from the hex digit (bits 3, 2, 1), tick, then check
// rdy (bit 0) + data (the line's recovered byte) when rdy is high.
static bool replay_ps2(VPS2* dut, FILE* f, Serial_mismatches* m) {
  unsigned int data;
  char trace[8192];
  if (fscanf(f, "%x %8191s", &data, trace) != 2) return false;
  int len = (int)strlen(trace);
  for (int k = 0; k < len; k++) {
    int hd = hexval(trace[k]);
    dut->done = (hd >> 3) & 1;
    dut->PS2C = (hd >> 2) & 1;
    dut->PS2D = (hd >> 1) & 1;
    tick(dut);
    int e_rdy = hd & 1;
    if (dut->rdy != e_rdy && ++m->wave <= 20)
      printf("WAVE-MISMATCH data=%02X cyc=%d: RTL rdy=%d PORT rdy=%d\n", data, k, dut->rdy, e_rdy);
    if (e_rdy && (unsigned)dut->data != data && ++m->value <= 20)
      printf("VALUE-MISMATCH cyc=%d: RTL data=%02X PORT=%02X\n", k, (unsigned)dut->data, data);
  }
  return true;
}

int main(int argc, char** argv) {
  return serial_cosim_main<VPS2>(argc, argv, { "ps2", "Ps2", "PS2.v" }, reset_ps2, replay_ps2);
}

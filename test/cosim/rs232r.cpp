// RTL-fidelity co-sim for Rs232r: replay each frame dumped by test/cosim/dump_rs232r through
// the reference test/_po/verilog/src/RS232R.v under Verilator, asserting cycle-by-cycle that RTL rdy
// == port's, plus RTL data == the recovered byte whenever rdy is high. Exit 0 iff bit- and
// cycle-exact to RS232R.v.   usage:  cosim <port_dump_path>     (lines: "fsel data hextrace")
//
// The receiver is input-driven, so this is a fixed-length trace replay (the shared
// reset/loop/stats boilerplate is run_serial_cosim in cosim.h; this file is just reset + replay).

#include "VRS232R.h"
#include "cosim.h" // run_serial_cosim(), hexval(), tick(), cosim_open()
#include <cstdio>
#include <cstring>

static void reset_rs232r(VRS232R* dut) {
  // rst active-low, synchronous; line idle high. Then frames run back-to-back.
  dut->rst = 0;
  dut->RxD = 1;
  dut->fsel = 0;
  dut->done = 0;
  tick(dut);
  dut->rst = 1;
  tick(dut);
}

// each cycle drive (rxd, done) from the hex digit (bits 1, 2), tick, then check rdy (bit 0) +
// data (the line's recovered byte) when rdy is high. [fsel] is per-line (a static config input).
static bool replay_rs232r(VRS232R* dut, FILE* f, Serial_mismatches* m) {
  int fsel;
  unsigned int data;
  char trace[65536];
  if (fscanf(f, "%d %x %65535s", &fsel, &data, trace) != 3) return false;
  dut->fsel = fsel;
  int len = (int)strlen(trace);
  for (int k = 0; k < len; k++) {
    int hd = hexval(trace[k]);
    dut->RxD = (hd >> 1) & 1;
    dut->done = (hd >> 2) & 1;
    tick(dut);
    int e_rdy = hd & 1;
    if (dut->rdy != e_rdy && ++m->wave <= 20)
      printf("WAVE-MISMATCH fsel=%d data=%02X cyc=%d: RTL rdy=%d PORT rdy=%d\n", fsel, data, k,
             dut->rdy, e_rdy);
    if (e_rdy && (unsigned)dut->data != data && ++m->value <= 20)
      printf("VALUE-MISMATCH fsel=%d cyc=%d: RTL data=%02X PORT=%02X\n", fsel, k,
             (unsigned)dut->data, data);
  }
  return true;
}

int main(int argc, char** argv) {
  return serial_cosim_main<VRS232R>(argc, argv, { "rs232r", "Rs232r", "RS232R.v" }, reset_rs232r,
                                    replay_rs232r);
}

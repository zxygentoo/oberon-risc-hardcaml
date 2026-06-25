// RTL-fidelity co-sim for Ps2: replay each frame dumped by test/cosim/dump_ps2 through the
// reference _po/verilog/src/PS2.v under Verilator, and assert — cycle-by-cycle — that RTL rdy ==
// port's, plus RTL data == the recovered byte whenever rdy is high. Exit 0 iff the Hardcaml port
// is bit-exact AND cycle-exact to PS2.v over the whole stimulus set.
//   usage:  cosim <port_dump_path>     (lines: "data hextrace")
//
// PS/2 is input-driven (the keyboard clocks us), so this is a fixed-length trace replay: each
// cycle drive (ps2c, ps2d, done) from the trace's hex digit (bits 2, 1, 3), tick, then check rdy
// (bit 0) + data (the line's recovered byte) when rdy is high. shift is ps2c-derived (Q1 & ~Q0)
// and trivially identical, so it isn't checked. Reuses fp_cosim.h's tick() + cosim_open(); hexval
// is local (it collapses into the shared header at the deferred serial dedup). Driven by run.sh.

#include "VPS2.h"
#include "fp_cosim.h" // tick(), cosim_open()
#include <cstdio>
#include <cstring>

static int hexval(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  return 0;
}

int main(int argc, char** argv) {
  FILE* f = cosim_open(argc, argv);
  if (!f) return 2;
  VPS2* dut = new VPS2;

  // reset: rst active-low, synchronous; ps2c/ps2d idle high. Then frames run back-to-back, each
  // ending with a done pop (recorded in the trace), matching the dumper.
  dut->rst = 0;
  dut->PS2C = 1;
  dut->PS2D = 1;
  dut->done = 0;
  tick(dut);
  dut->rst = 1;
  tick(dut);

  unsigned int data;
  char trace[8192];
  long n = 0, wave_mismatch = 0, value_mismatch = 0;

  while (fscanf(f, "%x %8191s", &data, trace) == 2) {
    int len = (int)strlen(trace);
    for (int k = 0; k < len; k++) {
      int hd = hexval(trace[k]);
      dut->done = (hd >> 3) & 1;
      dut->PS2C = (hd >> 2) & 1;
      dut->PS2D = (hd >> 1) & 1;
      tick(dut);
      int e_rdy = hd & 1;
      if (dut->rdy != e_rdy) {
        wave_mismatch++;
        if (wave_mismatch <= 20)
          printf("WAVE-MISMATCH data=%02X cyc=%d: RTL rdy=%d PORT rdy=%d\n", data, k, dut->rdy,
                 e_rdy);
      }
      if (e_rdy && (unsigned)dut->data != data) {
        value_mismatch++;
        if (value_mismatch <= 20)
          printf("VALUE-MISMATCH cyc=%d: RTL data=%02X PORT=%02X\n", k, (unsigned)dut->data, data);
      }
    }
    n++;
  }
  fclose(f);
  printf("ps2 co-sim: %ld stimuli, %ld value-mismatch, %ld wave-mismatch\n", n, value_mismatch,
         wave_mismatch);
  if (value_mismatch == 0 && wave_mismatch == 0)
    printf("==> Hardcaml Ps2 is bit-exact AND cycle-exact to PS2.v.\n");
  delete dut;
  return (value_mismatch == 0 && wave_mismatch == 0) ? 0 : 1;
}

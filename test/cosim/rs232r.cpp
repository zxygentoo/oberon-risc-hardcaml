// RTL-fidelity co-sim for Rs232r: replay each frame dumped by test/cosim/dump_rs232r through
// the reference _po/verilog/src/RS232R.v under Verilator, and assert — cycle-by-cycle — that
// RTL rdy == port's, plus RTL data == the recovered byte whenever rdy is high. Exit 0 iff the
// Hardcaml port is bit-exact AND cycle-exact to RS232R.v over the whole stimulus set.
//   usage:  cosim <port_dump_path>     (lines: "fsel data hextrace")
//
// The receiver is input-driven, so this is a fixed-length trace replay: each cycle drive
// (rxd, done) from the trace's hex digit (bits 1, 2), tick, then check rdy (bit 0) + data (the
// line's recovered byte) when rdy is high. Reuses fp_cosim.h's tick() + cosim_open(); hexval is
// local (it collapses into the shared header at the deferred serial dedup). Driven by run.sh.

#include "VRS232R.h"
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
  VRS232R* dut = new VRS232R;

  // reset: rst active-low, synchronous; line idle high. Then frames run back-to-back, each
  // ending with a done ack (recorded in the trace), matching the dumper.
  dut->rst = 0;
  dut->RxD = 1;
  dut->fsel = 0;
  dut->done = 0;
  tick(dut);
  dut->rst = 1;
  tick(dut);

  int fsel;
  unsigned int data;
  char trace[65536];
  long n = 0, wave_mismatch = 0, value_mismatch = 0;

  while (fscanf(f, "%d %x %65535s", &fsel, &data, trace) == 3) {
    dut->fsel = fsel;
    int len = (int)strlen(trace);
    for (int k = 0; k < len; k++) {
      int hd = hexval(trace[k]);
      dut->RxD = (hd >> 1) & 1;
      dut->done = (hd >> 2) & 1;
      tick(dut);
      int e_rdy = hd & 1;
      if (dut->rdy != e_rdy) {
        wave_mismatch++;
        if (wave_mismatch <= 20)
          printf("WAVE-MISMATCH fsel=%d data=%02X cyc=%d: RTL rdy=%d PORT rdy=%d\n", fsel, data, k,
                 dut->rdy, e_rdy);
      }
      if (e_rdy && (unsigned)dut->data != data) {
        value_mismatch++;
        if (value_mismatch <= 20)
          printf("VALUE-MISMATCH fsel=%d cyc=%d: RTL data=%02X PORT=%02X\n", fsel, k,
                 (unsigned)dut->data, data);
      }
    }
    n++;
  }
  fclose(f);
  printf("rs232r co-sim: %ld stimuli, %ld value-mismatch, %ld wave-mismatch\n", n, value_mismatch,
         wave_mismatch);
  if (value_mismatch == 0 && wave_mismatch == 0)
    printf("==> Hardcaml Rs232r is bit-exact AND cycle-exact to RS232R.v.\n");
  delete dut;
  return (value_mismatch == 0 && wave_mismatch == 0) ? 0 : 1;
}

// RTL-fidelity co-sim for Rs232t: replay each frame dumped by test/cosim/dump_rs232t through the
// reference _po/verilog/src/RS232T.v under Verilator, and assert — cycle-by-cycle — that RTL
// (rdy, TxD) == port's, plus frame length == port's. Exit 0 iff the Hardcaml port is bit-exact
// AND cycle-exact to RS232T.v over the whole stimulus set.
//   usage:  cosim <port_dump_path>     (lines: "fsel data cycles hextrace")
//
// RS232T is an output-only serial handshake unit: no per-cycle input (no MISO), so the .cpp
// drives only (fsel, data) and the hex trace carries just the port's outputs to check (bit1=rdy,
// bit0=txd). Like spi.cpp it reuses only fp_cosim.h's tick(). Driven by test/cosim/run.sh.

#include "VRS232T.h"
#include "fp_cosim.h" // tick()
#include <cstdio>
#include <cstring>

static int hexval(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  return 0;
}

// compare this cycle's RTL (rdy, TxD) against the port's, encoded in hex digit [hd].
// Returns 1 on mismatch (and prints the first 20), 0 otherwise.
static long wave_report(VRS232T* dut, int hd, int fsel, unsigned data, int k, long seen) {
  int e_rdy = (hd >> 1) & 1, e_txd = hd & 1;
  if (dut->rdy != e_rdy || dut->TxD != e_txd) {
    if (seen < 20)
      printf("WAVE-MISMATCH fsel=%d data=%02X cyc=%d: RTL(rdy=%d txd=%d) PORT(rdy=%d txd=%d)\n",
             fsel, data, k, dut->rdy, dut->TxD, e_rdy, e_txd);
    return 1;
  }
  return 0;
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
  VRS232T* dut = new VRS232T;
  const int CAP = 14000;

  // reset: rst active-low, synchronous; then frames run back-to-back (no per-frame reset),
  // matching the dumper.
  dut->rst = 0;
  dut->start = 0;
  dut->fsel = 0;
  dut->data = 0;
  tick(dut);
  dut->rst = 1;
  tick(dut);

  int fsel, pcyc;
  unsigned int data;
  char trace[16384];
  long n = 0, wave_mismatch = 0, cycle_mismatch = 0;

  while (fscanf(f, "%d %x %d %16383s", &fsel, &data, &pcyc, trace) == 4) {
    int tracelen = (int)strlen(trace);
    // edge 0: start sampled.
    dut->start = 1;
    dut->fsel = fsel;
    dut->data = data;
    tick(dut);
    wave_mismatch += wave_report(dut, hexval(trace[0]), fsel, data, 0, wave_mismatch);
    dut->start = 0;
    // drain until the RTL's own rdy re-raises (independent of the dump's length); pad past the
    // trace only on a divergence, already flagged by the cycle-count compare below.
    int rcyc = 1, k = 0;
    while (!dut->rdy && rcyc < CAP) {
      k++;
      tick(dut);
      if (k < tracelen)
        wave_mismatch += wave_report(dut, hexval(trace[k]), fsel, data, k, wave_mismatch);
      rcyc++;
    }
    n++;
    if (rcyc != pcyc) {
      cycle_mismatch++;
      if (cycle_mismatch <= 20)
        printf("CYCLE-MISMATCH fsel=%d data=%02X: RTL=%dcy PORT=%dcy\n", fsel, data, rcyc, pcyc);
    }
  }
  fclose(f);
  printf("rs232t co-sim: %ld stimuli, %ld wave-mismatch, %ld cycle-mismatch\n", n, wave_mismatch,
         cycle_mismatch);
  if (wave_mismatch == 0 && cycle_mismatch == 0)
    printf("==> Hardcaml Rs232t is bit-exact AND cycle-exact to RS232T.v.\n");
  delete dut;
  return (wave_mismatch == 0 && cycle_mismatch == 0) ? 0 : 1;
}

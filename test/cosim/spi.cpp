// RTL-fidelity co-sim for Spi: replay each transfer dumped by test/cosim/dump_spi through the
// reference _po/verilog/src/SPI.v under Verilator, and assert — cycle-by-cycle — that RTL
// (rdy, sclk, mosi) == port's, plus final dataRx == port's and cycle count == port's. Exit 0
// iff the Hardcaml port is bit-exact AND cycle-exact to SPI.v over the whole stimulus set.
//   usage:  cosim <port_dump_path>     (lines: "fast dataTx dataRx cycles hextrace")
//
// SPI is a serial handshake unit, not stall-based, so unlike the FP harnesses it does not use
// fp_cosim.h's drain — only its tick(). The MISO stimulus is read back from each cycle's hex
// digit (bit3) and replayed into the RTL; the digit's low three bits (rdy/sclk/mosi) are the
// port's expected outputs for that cycle. Driven by test/cosim/run.sh.

#include "VSPI.h"
#include "fp_cosim.h" // tick()
#include <cstdio>
#include <cstring>

static int hexval(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  return 0;
}

// compare this cycle's RTL (rdy,sclk,mosi) against the port's, encoded in hex digit [hd].
// Returns 1 on mismatch (and prints the first 20), 0 otherwise.
static long wave_report(VSPI* dut, int hd, int fast, unsigned dataTx, int k, long seen) {
  int e_rdy = (hd >> 2) & 1, e_sclk = (hd >> 1) & 1, e_mosi = hd & 1;
  if (dut->rdy != e_rdy || dut->SCLK != e_sclk || dut->MOSI != e_mosi) {
    if (seen < 20)
      printf("WAVE-MISMATCH fast=%d dataTx=%08X cyc=%d: RTL(rdy=%d sclk=%d mosi=%d) "
             "PORT(rdy=%d sclk=%d mosi=%d)\n",
             fast, dataTx, k, dut->rdy, dut->SCLK, dut->MOSI, e_rdy, e_sclk, e_mosi);
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
  VSPI* dut = new VSPI;
  const int CAP = 700;

  // reset: rst active-low, synchronous; then transfers run back-to-back (no per-transfer
  // reset), matching the dumper.
  dut->rst = 0;
  dut->start = 0;
  dut->fast = 0;
  dut->dataTx = 0;
  dut->MISO = 1;
  tick(dut);
  dut->rst = 1;
  tick(dut);

  int fast, pcyc;
  unsigned int dataTx, pdataRx;
  char trace[1024];
  long n = 0, value_mismatch = 0, wave_mismatch = 0, cycle_mismatch = 0;

  while (fscanf(f, "%d %x %x %d %1023s", &fast, &dataTx, &pdataRx, &pcyc, trace) == 5) {
    int tracelen = (int)strlen(trace);
    // edge 0: start sampled.
    dut->start = 1;
    dut->fast = fast;
    dut->dataTx = dataTx;
    int hd0 = hexval(trace[0]);
    dut->MISO = (hd0 >> 3) & 1;
    tick(dut);
    wave_mismatch += wave_report(dut, hd0, fast, dataTx, 0, wave_mismatch);
    dut->start = 0;
    // drain until the RTL's own rdy re-raises (independent of the dump's length), feeding the
    // recorded MISO each cycle; pad with 1 only if the RTL runs past the trace (a divergence,
    // already flagged by the cycle-count compare below).
    int rcyc = 1, k = 0;
    while (!dut->rdy && rcyc < CAP) {
      k++;
      int hd = (k < tracelen) ? hexval(trace[k]) : 0;
      dut->MISO = (k < tracelen) ? ((hd >> 3) & 1) : 1;
      tick(dut);
      if (k < tracelen) wave_mismatch += wave_report(dut, hd, fast, dataTx, k, wave_mismatch);
      rcyc++;
    }
    n++;
    if ((uint32_t)dut->dataRx != (uint32_t)pdataRx) {
      value_mismatch++;
      if (value_mismatch <= 20)
        printf("VALUE-MISMATCH fast=%d dataTx=%08X: RTL dataRx=%08X PORT=%08X\n", fast, dataTx,
               (uint32_t)dut->dataRx, pdataRx);
    }
    if (rcyc != pcyc) {
      cycle_mismatch++;
      if (cycle_mismatch <= 20)
        printf("CYCLE-MISMATCH fast=%d dataTx=%08X: RTL=%dcy PORT=%dcy\n", fast, dataTx, rcyc,
               pcyc);
    }
  }
  fclose(f);
  printf("spi co-sim: %ld stimuli, %ld value-mismatch, %ld wave-mismatch, %ld cycle-mismatch\n",
         n, value_mismatch, wave_mismatch, cycle_mismatch);
  if (value_mismatch == 0 && wave_mismatch == 0 && cycle_mismatch == 0)
    printf("==> Hardcaml Spi is bit-exact AND cycle-exact to SPI.v.\n");
  delete dut;
  return (value_mismatch == 0 && wave_mismatch == 0 && cycle_mismatch == 0) ? 0 : 1;
}

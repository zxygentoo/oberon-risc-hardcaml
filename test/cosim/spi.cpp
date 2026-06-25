// RTL-fidelity co-sim for Spi: replay each transfer dumped by test/cosim/dump_spi through the
// reference _po/verilog/src/SPI.v under Verilator, asserting cycle-by-cycle that RTL (rdy, sclk,
// mosi) == port's, plus final dataRx == port's and cycle count == port's. Exit 0 iff bit- and
// cycle-exact to SPI.v.   usage:  cosim <port_dump_path>  (lines: "fast dataTx dataRx cycles hextrace")
//
// Serial handshake (not stall-based): the MISO stimulus is read from each cycle's hex digit
// (bit3) and replayed into the RTL; the low three bits (rdy/sclk/mosi) are the port's expected
// outputs. Drain-until-rdy length is RTL-driven. Boilerplate shared (run_serial_cosim in cosim.h).

#include "VSPI.h"
#include "cosim.h" // run_serial_cosim(), hexval(), tick(), cosim_open()
#include <cstdio>
#include <cstring>

static const int CAP = 700;

static void reset_spi(VSPI* dut) {
  dut->rst = 0;
  dut->start = 0;
  dut->fast = 0;
  dut->dataTx = 0;
  dut->MISO = 1;
  tick(dut);
  dut->rst = 1;
  tick(dut);
}

// compare this cycle's RTL (rdy, sclk, mosi) against the port's, encoded in hex digit [hd].
static void check_spi(VSPI* dut, int hd, int fast, unsigned dataTx, int k, Serial_mismatches* m) {
  int e_rdy = (hd >> 2) & 1, e_sclk = (hd >> 1) & 1, e_mosi = hd & 1;
  if ((dut->rdy != e_rdy || dut->SCLK != e_sclk || dut->MOSI != e_mosi) && ++m->wave <= 20)
    printf("WAVE-MISMATCH fast=%d dataTx=%08X cyc=%d: RTL(rdy=%d sclk=%d mosi=%d) "
           "PORT(rdy=%d sclk=%d mosi=%d)\n",
           fast, dataTx, k, dut->rdy, dut->SCLK, dut->MOSI, e_rdy, e_sclk, e_mosi);
}

static bool replay_spi(VSPI* dut, FILE* f, Serial_mismatches* m) {
  int fast, pcyc;
  unsigned int dataTx, pdataRx;
  char trace[1024];
  if (fscanf(f, "%d %x %x %d %1023s", &fast, &dataTx, &pdataRx, &pcyc, trace) != 5) return false;
  int tracelen = (int)strlen(trace);
  // edge 0: start sampled.
  dut->start = 1;
  dut->fast = fast;
  dut->dataTx = dataTx;
  int hd0 = hexval(trace[0]);
  dut->MISO = (hd0 >> 3) & 1;
  tick(dut);
  check_spi(dut, hd0, fast, dataTx, 0, m);
  dut->start = 0;
  // drain until rdy re-raises, feeding the recorded MISO each cycle; pad with 1 past the trace.
  int rcyc = 1, k = 0;
  while (!dut->rdy && rcyc < CAP) {
    k++;
    int hd = (k < tracelen) ? hexval(trace[k]) : 0;
    dut->MISO = (k < tracelen) ? ((hd >> 3) & 1) : 1;
    tick(dut);
    if (k < tracelen) check_spi(dut, hd, fast, dataTx, k, m);
    rcyc++;
  }
  if ((uint32_t)dut->dataRx != (uint32_t)pdataRx && ++m->value <= 20)
    printf("VALUE-MISMATCH fast=%d dataTx=%08X: RTL dataRx=%08X PORT=%08X\n", fast, dataTx,
           (uint32_t)dut->dataRx, pdataRx);
  if (rcyc != pcyc && ++m->cycle <= 20)
    printf("CYCLE-MISMATCH fast=%d dataTx=%08X: RTL=%dcy PORT=%dcy\n", fast, dataTx, rcyc, pcyc);
  return true;
}

int main(int argc, char** argv) {
  FILE* f = cosim_open(argc, argv);
  if (!f) return 2;
  VSPI* dut = new VSPI;
  int rc = run_serial_cosim(Unit{ "spi", "Spi", "SPI.v" }, dut, f, reset_spi, replay_spi);
  delete dut;
  return rc;
}

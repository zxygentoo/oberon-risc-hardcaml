// RTL-fidelity co-sim for Rs232t: replay each frame dumped by test/cosim/dump_rs232t through the
// reference test/_po/verilog/src/RS232T.v under Verilator, asserting cycle-by-cycle that RTL (rdy,
// TxD) == port's, plus frame length == port's. Exit 0 iff bit- and cycle-exact to RS232T.v.
//   usage:  cosim <port_dump_path>     (lines: "fsel data cycles hextrace")
//
// Output-only serial handshake: no per-cycle input, so we drive only (fsel, data) at edge 0 and
// the trace carries just the outputs to check (bit1=rdy, bit0=txd). Drain-until-rdy length is
// RTL-driven. The reset/loop/stats boilerplate is shared (run_serial_cosim in cosim.h).

#include "VRS232T.h"
#include "cosim.h" // run_serial_cosim(), hexval(), tick(), cosim_open()
#include <cstdio>
#include <cstring>

static const int CAP = 14000;

static void reset_rs232t(VRS232T* dut) {
  dut->rst = 0;
  dut->start = 0;
  dut->fsel = 0;
  dut->data = 0;
  tick(dut);
  dut->rst = 1;
  tick(dut);
}

// compare this cycle's RTL (rdy, TxD) against the port's, encoded in hex digit [hd].
static void check_txd(VRS232T* dut, int hd, int fsel, unsigned data, int k, Serial_mismatches* m) {
  int e_rdy = (hd >> 1) & 1, e_txd = hd & 1;
  if ((dut->rdy != e_rdy || dut->TxD != e_txd) && ++m->wave <= 20)
    printf("WAVE-MISMATCH fsel=%d data=%02X cyc=%d: RTL(rdy=%d txd=%d) PORT(rdy=%d txd=%d)\n", fsel,
           data, k, dut->rdy, dut->TxD, e_rdy, e_txd);
}

static bool replay_rs232t(VRS232T* dut, FILE* f, Serial_mismatches* m) {
  int fsel, pcyc;
  unsigned int data;
  char trace[16384];
  if (fscanf(f, "%d %x %d %16383s", &fsel, &data, &pcyc, trace) != 4) return false;
  int tracelen = (int)strlen(trace);
  // edge 0: start sampled.
  dut->start = 1;
  dut->fsel = fsel;
  dut->data = data;
  tick(dut);
  check_txd(dut, hexval(trace[0]), fsel, data, 0, m);
  dut->start = 0;
  // drain until the RTL's own rdy re-raises (independent of the dump's length); pad past the
  // trace only on a divergence, already flagged by the cycle-count compare.
  int rcyc = 1, k = 0;
  while (!dut->rdy && rcyc < CAP) {
    k++;
    tick(dut);
    if (k < tracelen) check_txd(dut, hexval(trace[k]), fsel, data, k, m);
    rcyc++;
  }
  if (rcyc != pcyc && ++m->cycle <= 20)
    printf("CYCLE-MISMATCH fsel=%d data=%02X: RTL=%dcy PORT=%dcy\n", fsel, data, rcyc, pcyc);
  return true;
}

int main(int argc, char** argv) {
  return serial_cosim_main<VRS232T>(argc, argv, { "rs232t", "Rs232t", "RS232T.v" }, reset_rs232t,
                                    replay_rs232t);
}

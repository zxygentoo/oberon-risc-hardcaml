// RTL-fidelity co-sim for Vid: replay the per-tick trace dumped by test/cosim/dump_vid through
// the reference _po/verilog/src/VID60.v (wrapped by vid_cosim.v) under Verilator, and assert —
// every base tick — that RTL (req, vidadr, hsync, vsync, RGB) == the Hardcaml port's. Exit 0 iff
// the port is bit- and cycle-exact to VID60.v over the whole stimulus.
//   usage:  cosim <port_dump_path>   (lines: "inv viddata req vidadr hsync vsync rgb")
//
// VID is two-clock: clk (25 MHz) is VID's real input, pclk (65 MHz) is forced into VID's internal
// net by the wrapper. We drive both on a fine base tick at the 13:5 ratio — clk rises at t%13==0,
// pclk at t%5==0 — matching the dumper's By_input_clocks model (a clock edges when t%period==0).
// One eval() per tick. Reuses fp_cosim.h's cosim_open (the two-clock tick is local).

#include "Vvid_cosim.h"
#include "fp_cosim.h" // cosim_open()
#include <cstdio>

int main(int argc, char** argv) {
  FILE* f = cosim_open(argc, argv);
  if (!f) return 2;
  Vvid_cosim* dut = new Vvid_cosim;

  long t = 0, n = 0, mismatch = 0;
  int inv, req, hsync, vsync, rgb;
  unsigned int viddata, vidadr;

  while (fscanf(f, "%d %x %d %x %d %d %x", &inv, &viddata, &req, &vidadr, &hsync, &vsync, &rgb) ==
         7) {
    dut->inv = inv;
    dut->viddata = viddata;
    // The dumper reads outputs after Cyclesim.cycle, where a clock edges when its 1-indexed
    // cycle count divides the period and line t reflects cycles <= t+1; so a clock's rising
    // edge lands at line t where (t+1)%period==0. Match that phase here (+1), else the two are
    // one tick out and every domain mismatches by a clock period.
    dut->clk = ((t + 1) % 13 == 0) ? 1 : 0; // 25 MHz
    dut->pclk = ((t + 1) % 5 == 0) ? 1 : 0; // 65 MHz
    dut->eval();

    int rgb_rtl = dut->RGB & 0x3f;
    if (dut->req != req || (unsigned)dut->vidadr != vidadr || dut->hsync != hsync ||
        dut->vsync != vsync || rgb_rtl != rgb) {
      mismatch++;
      if (mismatch <= 20)
        printf("MISMATCH t=%ld: RTL req=%d adr=%05x hs=%d vs=%d rgb=%02x | PORT req=%d adr=%05x "
               "hs=%d vs=%d rgb=%02x\n",
               t, dut->req, (unsigned)dut->vidadr, dut->hsync, dut->vsync, rgb_rtl, req, vidadr,
               hsync, vsync, rgb);
    }
    n++;
    t++;
  }
  fclose(f);
  printf("vid co-sim: %ld ticks, %ld mismatch\n", n, mismatch);
  if (mismatch == 0) printf("==> Hardcaml Vid is bit-exact AND cycle-exact to VID60.v.\n");
  delete dut;
  return mismatch == 0 ? 0 : 1;
}

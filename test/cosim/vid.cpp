// RTL-fidelity co-sim for Vid: replay the per-tick trace dumped by test/cosim/vid_dump through
// the reference test/_po/verilog/src/VID60.v (wrapped by vid_cosim.v) under Verilator, and assert —
// every base tick — that RTL (vidadr, hsync, vsync, RGB) == the Hardcaml port's. Exit 0 iff the
// port is bit- and cycle-exact to VID60.v on the raster + pixel datapath over the whole stimulus.
//   usage:  cosim <port_dump_path>   (lines: "inv viddata req vidadr hsync vsync rgb")
//
// [req] is the one DELIBERATE departure (see lib/vid.ml): our toggle pulse-synchroniser fires the
// framebuffer-fetch request ~2 clk later than VID60.v's async-set [req1] (a metastability-safe
// substitute the RTL's async idiom can't be in Cyclesim/on silicon). So [req] is NOT compared
// cycle-exact — that's exactly what the formal layer does too (the equiv proof CUTS req; a separate
// k-induction proves its protocol: one req per req0, no loss, no spurious). Here we keep an
// integrated-level sanity: both sides must emit the SAME NUMBER of req pulses over the run (±1, for
// the one fetch the synchroniser may hold in flight at the trace boundary).
//
// VID is two-clock: clk (25 MHz) is VID's real input, pclk (65 MHz) is forced into VID's internal
// net by the wrapper. We drive both on a fine base tick at the 13:5 ratio — clk rises at t%13==0,
// pclk at t%5==0 — matching the dumper's By_input_clocks model (a clock edges when t%period==0).
// One eval() per tick. Reuses cosim.h's cosim_open (the two-clock tick is local).

#include "Vvid_cosim.h"
#include "cosim.h" // cosim_open()
#include <cstdio>

int main(int argc, char** argv) {
  FILE* f = cosim_open(argc, argv);
  if (!f) return 2;
  Vvid_cosim* dut = new Vvid_cosim;

  long t = 0, n = 0, mismatch = 0;
  long req_rtl_pulses = 0, req_port_pulses = 0; // rising edges = fetches (the req protocol)
  int prev_req_rtl = 0, prev_req_port = 0;
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

    // count req pulses on each side (protocol check); don't compare req cycle-exact (departure)
    if (dut->req && !prev_req_rtl) req_rtl_pulses++;
    if (req && !prev_req_port) req_port_pulses++;
    prev_req_rtl = dut->req;
    prev_req_port = req;

    int rgb_rtl = dut->RGB & 0x3f;
    if ((unsigned)dut->vidadr != vidadr || dut->hsync != hsync || dut->vsync != vsync ||
        rgb_rtl != rgb) {
      mismatch++;
      if (mismatch <= 20)
        printf("MISMATCH t=%ld: RTL adr=%05x hs=%d vs=%d rgb=%02x | PORT adr=%05x hs=%d vs=%d "
               "rgb=%02x\n",
               t, (unsigned)dut->vidadr, dut->hsync, dut->vsync, rgb_rtl, vidadr, hsync, vsync,
               rgb);
    }
    n++;
    t++;
  }
  fclose(f);
  long req_diff = req_rtl_pulses - req_port_pulses;
  int req_ok = req_diff <= 1 && req_diff >= -1;
  printf("vid co-sim: %ld ticks, %ld mismatch (raster+pixels); req pulses RTL=%ld PORT=%ld%s\n", n,
         mismatch, req_rtl_pulses, req_port_pulses, req_ok ? "" : "  <-- REQ COUNT MISMATCH");
  if (mismatch == 0 && req_ok)
    printf("==> Hardcaml Vid: raster+pixels bit/cycle-exact to VID60.v; req protocol matches "
           "(req timing deliberately departs — see lib/vid.ml + test/formal vid_invariant).\n");
  delete dut;
  return (mismatch == 0 && req_ok) ? 0 : 1;
}

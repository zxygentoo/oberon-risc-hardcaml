// RTL-fidelity co-sim for Vid: replay the per-tick trace dumped by test/cosim/vid_dump through
// the reference test/_po/verilog/src/VID60.v (wrapped by vid_cosim.v) under Verilator, and assert —
// every base tick — that RTL (hsync, vsync, RGB) == the Hardcaml port's. [req] is checked by pulse
// COUNT and [vidadr] is NOT compared — both are DELIBERATE departures (see below). Exit 0 iff the
// port is bit- and cycle-exact to VID60.v on the raster + pixels over the stimulus.
//   usage:  cosim <port_dump_path>   (lines: "inv viddata req vidadr hsync vsync rgb")
//
// TWO deliberate departures from VID60.v (see lib/vid.ml):
//  1. [req] CDC — our toggle pulse-synchroniser fires the framebuffer-fetch request ~2 clk later
//     than VID60.v's async-set [req1] (a metastability-safe substitute the RTL's async idiom can't
//     be in Cyclesim/on silicon). So [req] is NOT compared cycle-exact — the formal layer does the
//     same (the equiv proof CUTS req; a k-induction proves its protocol: one req per req0, no loss,
//     no spurious). Here we keep an integrated sanity: both sides must emit the SAME NUMBER of req
//     pulses over the run (+-1, for the one fetch a synchroniser may hold in flight at the boundary).
//  2. [vidadr] PREFETCH — our 2-group prefetch issues the read one group EARLY, so our [vidadr]
//     leads VID60.v's by one column every tick. So [vidadr] is NOT compared (the equiv excludes it
//     too); that the look-ahead DELIVERS the right word is the lib/vid.ml prefetch test's job.
//
// Identity-echo framebuffer. Because the prefetch makes our address and VID60.v's differ every
// tick, a single replayed [viddata] stream can't be correct for both. Instead BOTH sides read an
// identity framebuffer (mem[a] = a): the dumper drove our [viddata] = our [vidadr], and here we
// drive VID60.v's [viddata] = VID60.v's OWN [vidadr]. [vidadr] is stable across a 32-px group, so
// each side samples its own correctly-addressed word regardless of the req CDC's phase OR the
// prefetch's lead — both then render the SAME pixels (col's word in group col+1), so RGB stays
// comparable cycle-exact. (This is the sim analogue of the equiv proof cutting [vidbuf] to a shared
// free input and comparing the pixel datapath GIVEN the same word.)
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

  // settle combinational outputs (vidadr) from the reset registers before the first echo
  dut->clk = 0;
  dut->pclk = 0;
  dut->inv = 0;
  dut->viddata = 0;
  dut->eval();

  long t = 0, n = 0, mismatch = 0;
  long req_rtl_pulses = 0, req_port_pulses = 0; // rising edges = fetches (the req protocol)
  int prev_req_rtl = 0, prev_req_port = 0;
  int inv, req, hsync, vsync, rgb;
  unsigned int viddata, vidadr;

  // Skip RGB comparison over the first scanline. The 2-group prefetch sources each column's word
  // from a ping-pong buffer fetched a group early; column 0 of the very FIRST frame would have been
  // fetched at the end of the (nonexistent) previous frame, so it reads a cold buffer — a one-group
  // frame-top gap that self-heals after one line. VID60.v has no such gap (its address tracks the
  // current group), so the two differ ONLY here. (Same alignment the lib/vid.ml prefetch test makes
  // with vcnt>=2.) Raster (hsync/vsync) and the req protocol are checked from t=0.
  const long RGB_WARMUP_TICKS = 1344 * 5; // one scanline

  while (fscanf(f, "%d %x %d %x %d %d %x", &inv, &viddata, &req, &vidadr, &hsync, &vsync, &rgb) ==
         7) {
    (void)viddata; // the file's viddata is the PORT's own echoed address — informational here;
                   // VID60.v is driven from its OWN vidadr below
    dut->inv = inv;
    // identity-echo: drive VID60.v's viddata from its own vidadr (mem[a]=a), as the dumper did ours
    dut->viddata = dut->vidadr;
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
    bool cmp_rgb = t >= RGB_WARMUP_TICKS;
    if (dut->hsync != hsync || dut->vsync != vsync || (cmp_rgb && rgb_rtl != rgb)) {
      mismatch++;
      if (mismatch <= 20)
        printf("MISMATCH t=%ld: RTL hs=%d vs=%d rgb=%02x (adr=%05x) | PORT hs=%d vs=%d rgb=%02x "
               "(adr=%05x)\n",
               t, dut->hsync, dut->vsync, rgb_rtl, (unsigned)dut->vidadr, hsync, vsync, rgb, vidadr);
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
    printf("==> Hardcaml Vid: raster bit/cycle-exact to VID60.v and pixels match on an identity "
           "framebuffer; req + vidadr deliberately depart (CDC synchroniser + 2-group prefetch — "
           "see lib/vid.ml, test/formal vid_invariant, and the prefetch look-ahead lib test).\n");
  delete dut;
  return (mismatch == 0 && req_ok) ? 0 : 1;
}

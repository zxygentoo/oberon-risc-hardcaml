// Boot-stream RTL co-sim for the CPU core (AGENT.md §6 layer 3, extended to the whole core).
// Replays the per-cycle core I/O captured by test/dump_core_trace (over the real Oberon boot)
// through the reference test/_po/verilog/src/RISC5.v under Verilator, and reports the FIRST cycle
// our core's outputs diverge from the spec — the instruction where our port deviates from
// RISC5.v. (This is what found + verified the phase-6b ALU flag-leak fix.)
//
// Why the first output mismatch is exactly the divergence: see test/dump_core_trace.ml. Both
// cores start from the same reset state; fed the identical captured inputs, they stay in
// lockstep (identical memory -> identical inputs) until our core first does something RISC5.v
// wouldn't — which is the first output mismatch here.
//
// Trace format: 17-byte little-endian records, one per cycle:
//   byte0 = rst | irq<<1 | stallX<<2 | rd<<3 | wr<<4 | ben<<5 ; then codebus,inbus,adr,outbus (u32)
// codebus/inbus/irq/stallX (+ rst) are the core INPUTS we drive into RISC5.v; adr/rd/wr/ben/
// outbus are the OUTPUTS we compare.
//
// usage: risc5_cosim <trace> [skip]   skip = leading records compared-skipped (default 2: the
//        reset transient. cyc0 is the rst=0 reset cycle; cyc1 differs benignly because our port
//        models reset via the PC register's reset value, so its combinational adr reaches
//        StartAdr one cycle after RISC5.v's `~rst ? StartAdr` term in pcmux. Both re-converge at
//        cyc2 and stay in lockstep — the replay still DRIVES cyc0/cyc1 (so RTL reaches the right
//        state), it just doesn't COMPARE them.

#include "VRISC5.h"
#include "cosim.h"  // tick(), Verilated
#include <cstdint>
#include <cstdio>
#include <cstdlib>

struct Rec {
  long cyc;
  int rst, irq, stallx, rd, wr, ben;
  uint32_t codebus, inbus, adr, outbus;
};

static bool read_rec(FILE* f, Rec* r) {
  unsigned char b[17];
  if (fread(b, 1, 17, f) != 17) return false;
  int c = b[0];
  r->rst = c & 1;
  r->irq = (c >> 1) & 1;
  r->stallx = (c >> 2) & 1;
  r->rd = (c >> 3) & 1;
  r->wr = (c >> 4) & 1;
  r->ben = (c >> 5) & 1;
  r->codebus = (uint32_t)b[1] | (uint32_t)b[2] << 8 | (uint32_t)b[3] << 16 | (uint32_t)b[4] << 24;
  r->inbus = (uint32_t)b[5] | (uint32_t)b[6] << 8 | (uint32_t)b[7] << 16 | (uint32_t)b[8] << 24;
  r->adr = (uint32_t)b[9] | (uint32_t)b[10] << 8 | (uint32_t)b[11] << 16 | (uint32_t)b[12] << 24;
  r->outbus =
    (uint32_t)b[13] | (uint32_t)b[14] << 8 | (uint32_t)b[15] << 16 | (uint32_t)b[16] << 24;
  return true;
}

static const int RING = 24;  // recent records dumped for context at the first divergence

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  if (argc < 2) {
    fprintf(stderr, "usage: %s <trace> [skip]\n", argv[0]);
    return 2;
  }
  FILE* f = fopen(argv[1], "rb");
  if (!f) {
    fprintf(stderr, "cannot open %s\n", argv[1]);
    return 2;
  }
  long skip = (argc >= 3) ? atol(argv[2]) : 2;
  const char* maxc = getenv("MAXCYC");
  long maxcyc = maxc ? atol(maxc) : -1;

  Rec rec;
  if (!read_rec(f, &rec)) {
    fprintf(stderr, "empty trace\n");
    return 2;
  }

  VRISC5* dut = new VRISC5;

  // The trace is recorded PRE-edge (see test/dump_core_trace.ml): rec[k] = (inputs state k
  // consumes, outputs state k drives), and the edge transitions state k -> state k+1. So we
  // drive rec[k]'s inputs (rst verbatim — rec[0] is the rst=0 reset cycle that forces
  // PC<=StartAdr on its own edge), settle, compare the outputs, then clock. No separate reset
  // tick is needed, and because the codebus consumed at the first rst=1 edge (the branch
  // target) is in the trace, the reset boundary stays in lockstep. skip defaults to 0.

  Rec ring[RING];
  long ring_n = 0;
  long k = 0, mism = 0, first_mism = -1;
  bool have = true;
  for (; have; k++, have = read_rec(f, &rec)) {
    if (maxcyc >= 0 && k >= maxcyc) break;
    rec.cyc = k;
    // dut is at S_{k+1}; rec = cloud(S_{k+1}). Drive RISC5.v with rec's inputs (rst
    // deasserted), settle, compare the outputs, then tick to S_{k+2} using the same inputs.
    dut->rst = rec.rst;
    dut->irq = rec.irq;
    dut->stallX = rec.stallx;
    dut->codebus = rec.codebus;
    dut->inbus = rec.inbus;
    dut->clk = 0;
    dut->eval();  // settle cloud(S_{k+1})

    uint32_t r_adr = dut->adr & 0xFFFFFF;
    int r_rd = dut->rd, r_wr = dut->wr, r_ben = dut->ben;
    uint32_t r_outbus = dut->outbus;
    bool match = r_adr == (rec.adr & 0xFFFFFF) && r_rd == rec.rd && r_wr == rec.wr
                 && r_ben == rec.ben && r_outbus == rec.outbus;

    ring[ring_n % RING] = rec;
    ring_n++;

    if (k < 8 || (k >= skip && !match && mism < 4))
      printf("  cyc %8ld: %s  RTL[adr=%06X rd=%d wr=%d ben=%d out=%08X] PORT[adr=%06X rd=%d "
             "wr=%d ben=%d out=%08X] code=%08X in=%08X\n",
             k, match ? "ok " : "DIFF", r_adr, r_rd, r_wr, r_ben, r_outbus, rec.adr & 0xFFFFFF,
             rec.rd, rec.wr, rec.ben, rec.outbus, rec.codebus, rec.inbus);

    if (k >= skip && !match) {
      if (mism == 0) {
        first_mism = k;
        printf("\n==== FIRST DIVERGENCE at trace cycle %ld ====\n", k);
        printf("  RTL : adr=%06X rd=%d wr=%d ben=%d outbus=%08X\n", r_adr, r_rd, r_wr, r_ben,
               r_outbus);
        printf("  PORT: adr=%06X rd=%d wr=%d ben=%d outbus=%08X\n", rec.adr & 0xFFFFFF, rec.rd,
               rec.wr, rec.ben, rec.outbus);
        printf("  --- last %d records (cyc: code[next IR]  adr rd wr ben outbus inbus) ---\n",
               RING);
        long start = ring_n > RING ? ring_n - RING : 0;
        for (long j = start; j < ring_n; j++) {
          Rec* x = &ring[j % RING];
          printf("  %8ld: code=%08X adr=%06X rd=%d wr=%d ben=%d out=%08X in=%08X%s\n", x->cyc,
                 x->codebus, x->adr, x->rd, x->wr, x->ben, x->outbus, x->inbus,
                 j == ring_n - 1 ? "  <== MISMATCH" : "");
        }
      }
      mism++;
      if (mism > 5000) {
        printf("... >5000 mismatches; stopping (inputs are contaminated past the first "
               "divergence)\n");
        break;
      }
    }
    dut->clk = 1;
    dut->eval();  // tick S_{k+1} -> S_{k+2}
  }
  fclose(f);
  if (mism == 0)
    printf("\nNO DIVERGENCE over %ld cycles — our core is RTL-identical to RISC5.v across the "
           "whole captured boot.\n",
           k);
  else
    printf("\nfirst divergence at cycle %ld; %ld mismatching cycles after it\n", first_mism, mism);
  delete dut;
  return mism == 0 ? 0 : 1;
}

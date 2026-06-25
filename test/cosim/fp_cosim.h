// Shared harness for the RTL co-sims. The Verilator top types are unrelated generated
// classes but duck-typed, so the clock tick and the stall-based run -> drain -> compare
// protocol are templated here once and the per-unit .cpp just names its unit + stimulus
// parser. The FP units (run/stall/z) share the full runner below; the serial units (SPI,
// RS232T) still keep their own main() and reuse only tick() — deduping those is a deferred
// 6a-end clean-up (a shared serial runner + rename to cosim.h; see test/cosim/README.md).
#pragma once
#include "verilated.h"
#include <cstdint>
#include <cstdio>

// one clock cycle: falling then rising edge, evaluating combinational logic at each.
template <typename Dut> static void tick(Dut* dut) {
  dut->clk = 0;
  dut->eval();
  dut->clk = 1;
  dut->eval();
}

// open the port-dump path given on argv (the single CLI arg every harness takes); prints a
// usage/error and returns null on failure. Universal to all co-sims.
static FILE* cosim_open(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  if (argc < 2) {
    fprintf(stderr, "usage: %s <port_dump_path>\n", argv[0]);
    return nullptr;
  }
  FILE* f = fopen(argv[1], "r");
  if (!f) fprintf(stderr, "cannot open %s\n", argv[1]);
  return f;
}

// the three name strings a cross-check prints: [tag] in the stats line, "[port] is bit-exact
// ... to [rtl]" in the success line.
struct Unit {
  const char* tag; // e.g. "fp_adder"
  const char* port; // e.g. "Fp_adder"
  const char* rtl; // e.g. "FPAdder.v"
};

// assert run, drain until stall drops, read z, then release run for one cycle. Returns z;
// *cycles = the clock cycles with run asserted until stall drops (the stall length),
// counted identically to dump_fp's port-side drive so the two are directly comparable. The
// caller sets the unit's data inputs (x/y and any u/v) before calling.
template <typename Dut> static uint32_t drain(Dut* dut, int* cycles) {
  dut->run = 1;
  tick(dut);
  int c = 1;
  while (dut->stall && c < 40) {
    tick(dut);
    c++;
  }
  uint32_t z = dut->z;
  dut->run = 0;
  tick(dut);
  *cycles = c;
  return z;
}

// run a stall-based (run -> drain -> z) cross-check end to end: for each dumped line, [parse]
// sets the DUT's inputs and yields the port's (z, cycles) + a label; drain the RTL and compare
// z and the stall length. Prints the stats + success lines and returns the process exit code
// (0 iff bit- and cycle-exact). [parse] returns false at EOF.
template <typename Dut, typename Parse>
static int run_drain_cosim(Unit unit, Dut* dut, FILE* f, Parse parse) {
  uint32_t pz;
  int pcyc;
  char label[128];
  long n = 0, value_mismatch = 0, cycle_mismatch = 0;
  while (parse(f, dut, &pz, &pcyc, label)) {
    int rcyc = 0;
    uint32_t rz = drain(dut, &rcyc);
    n++;
    if (rz != pz) {
      value_mismatch++;
      if (value_mismatch <= 20) printf("VALUE-MISMATCH %s: RTL=%08X PORT=%08X\n", label, rz, pz);
    }
    if (rcyc != pcyc) {
      cycle_mismatch++;
      if (cycle_mismatch <= 20)
        printf("CYCLE-MISMATCH %s: RTL=%dcy PORT=%dcy\n", label, rcyc, pcyc);
    }
  }
  fclose(f);
  printf("%s co-sim: %ld stimuli, %ld value-mismatch, %ld cycle-mismatch\n", unit.tag, n,
         value_mismatch, cycle_mismatch);
  if (value_mismatch == 0 && cycle_mismatch == 0)
    printf("==> Hardcaml %s is bit-exact AND cycle-exact to %s.\n", unit.port, unit.rtl);
  return (value_mismatch == 0 && cycle_mismatch == 0) ? 0 : 1;
}

// stimulus parsers for run_drain_cosim. mul/div carry no modifiers ("x y z cyc"); the adder
// carries u/v ("x y u v z cyc"). Templated on the DUT so each sets only the inputs its RTL has
// (parse_xyuv is instantiated for the adder alone, which is the only top with u/v).
template <typename Dut>
static bool parse_xy(FILE* f, Dut* dut, uint32_t* pz, int* pcyc, char* label) {
  unsigned int x, y, z;
  int cyc;
  if (fscanf(f, "%x %x %x %d", &x, &y, &z, &cyc) != 4) return false;
  dut->x = x;
  dut->y = y;
  *pz = z;
  *pcyc = cyc;
  snprintf(label, 128, "x=%08X y=%08X", x, y);
  return true;
}

template <typename Dut>
static bool parse_xyuv(FILE* f, Dut* dut, uint32_t* pz, int* pcyc, char* label) {
  unsigned int x, y, z;
  int u, v, cyc;
  if (fscanf(f, "%x %x %d %d %x %d", &x, &y, &u, &v, &z, &cyc) != 6) return false;
  dut->u = u;
  dut->v = v;
  dut->x = x;
  dut->y = y;
  *pz = z;
  *pcyc = cyc;
  snprintf(label, 128, "x=%08X y=%08X u=%d v=%d", x, y, u, v);
  return true;
}

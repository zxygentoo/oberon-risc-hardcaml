// Shared harness helpers for the FP-unit RTL co-sims (fp_adder/multiplier/divider.cpp).
// The Verilator top types (VFPAdder/VFPMultiplier/VFPDivider) all expose the same
// clk/run/stall/z/eval() interface, so the clock tick and the run -> drain -> count
// protocol are one templated definition here. Each unit's .cpp keeps its own main(): they
// differ in the modifier inputs (the adder carries u/v, mul/div don't) and the dumped-line
// arity, which doesn't pay for a shared, trait-laden runner. See test/cosim/README.md.
#pragma once
#include "verilated.h"
#include <cstdint>

// one clock cycle: falling then rising edge, evaluating combinational logic at each.
template <typename Dut> static void tick(Dut* dut) {
  dut->clk = 0;
  dut->eval();
  dut->clk = 1;
  dut->eval();
}

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

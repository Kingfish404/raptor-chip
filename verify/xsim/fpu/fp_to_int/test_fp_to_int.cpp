#include <verilated.h>
#include "Vrapt_fpu_fp_to_int_tb.h"
#include <cfenv>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <limits>
#include <random>

#pragma STDC FENV_ACCESS ON

static void tick(Vrapt_fpu_fp_to_int_tb &dut) {
  dut.clock = 0; dut.eval();
  dut.clock = 1; dut.eval();
}

static long double round_value(long double value, unsigned rm) {
  switch (rm) {
    case 0: return std::nearbyint(value);
    case 1: return std::trunc(value);
    case 2: return std::floor(value);
    case 3: return std::ceil(value);
    default: {
      long double base = std::trunc(value);
      long double fraction = std::fabs(value - base);
      return fraction >= 0.5L ? base + std::copysign(1.0L, value) : base;
    }
  }
}

struct Expected { uint64_t result; uint8_t flags; };

static Expected reference(uint64_t bits, bool source_double, bool uns, bool int64, unsigned rm) {
  long double value;
  bool nan;
  if (source_double) {
    double input; std::memcpy(&input, &bits, sizeof(input));
    value = input; nan = std::isnan(input);
  } else {
    uint32_t raw = bits >> 32 == UINT32_MAX ? uint32_t(bits) : 0x7fc00000U;
    float input; std::memcpy(&input, &raw, sizeof(input));
    value = input; nan = std::isnan(input);
  }
  long double rounded = round_value(value, rm);
  long double lower = uns ? 0.0L : (int64 ? -std::ldexp(1.0L, 63) : -std::ldexp(1.0L, 31));
  long double upper = uns ? (int64 ? std::ldexp(1.0L, 64) - 1 : std::ldexp(1.0L, 32) - 1)
                          : (int64 ? std::ldexp(1.0L, 63) - 1 : std::ldexp(1.0L, 31) - 1);
  bool invalid = !std::isfinite(value) || rounded < lower || rounded > upper;
  uint64_t result;
  if (invalid) {
    if (uns) result = (!nan && std::signbit(value)) ? 0 : (int64 ? UINT64_MAX : UINT32_MAX);
    else if (nan || !std::signbit(value)) result = int64 ? INT64_MAX : INT32_MAX;
    else result = int64 ? uint64_t(INT64_MIN) : uint32_t(INT32_MIN);
  } else if (uns) result = uint64_t(rounded);
  else result = uint64_t(int64_t(rounded));
  if (!int64) result = uint64_t(int64_t(int32_t(result)));
  return {result, uint8_t((invalid ? 0x10 : 0) | (!invalid && rounded != value ? 1 : 0))};
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  unsigned iterations = argc > 1 ? std::stoul(argv[1]) : 200000;
  Vrapt_fpu_fp_to_int_tb dut;
  dut.reset = 1; dut.flush = 0; dut.valid = 0; tick(dut); tick(dut); dut.reset = 0;
  std::mt19937_64 rng(0x6670746f696e74ULL);
  unsigned errors = 0;
  for (unsigned index = 0; index < iterations; ++index) {
    bool source_double = rng() & 1, uns = rng() & 1, int64 = rng() & 1;
    unsigned rm = rng() % 5; uint64_t operand = rng();
    if (!source_double && (rng() & 7)) operand |= 0xffffffff00000000ULL;
    Expected expected = reference(operand, source_double, uns, int64, rm);
    dut.source_double = source_double; dut.unsigned_result = uns; dut.int64_target = int64;
    dut.rounding_mode = rm; dut.operand = operand; dut.valid = 1; tick(dut); dut.valid = 0;
    while (!dut.dut_valid) tick(dut);
    if (dut.dut_result != expected.result || dut.dut_flags != expected.flags) {
      if (errors++ < 20) std::cerr << std::hex << "op=" << operand << " sd=" << source_double
        << " u=" << uns << " l=" << int64 << " rm=" << rm << " got=" << dut.dut_result
        << "/" << unsigned(dut.dut_flags) << " exp=" << expected.result << "/"
        << unsigned(expected.flags) << std::dec << "\n";
    }
    tick(dut);
  }
  std::cout << "fp_to_int cases=" << iterations << " errors=" << errors << "\n";
  return errors != 0;
}

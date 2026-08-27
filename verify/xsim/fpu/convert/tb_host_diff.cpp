#include <cfenv>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "Vrapt_fpu_convert_tb.h"
#include "verilated.h"

static Vrapt_fpu_convert_tb* top;
static uint64_t rng = 0x243f6a8885a308d3ULL;

static void tick() {
  top->clock = 0;
  top->eval();
  top->clock = 1;
  top->eval();
}

static void reset() {
  top->reset = 1;
  top->valid = 0;
  top->flush = 0;
  for (int index = 0; index < 4; ++index) tick();
  top->reset = 0;
  tick();
}

static uint64_t random64() {
  rng ^= rng << 13;
  rng ^= rng >> 7;
  rng ^= rng << 17;
  return rng;
}

static uint32_t generate32(int mode) {
  const uint32_t value = static_cast<uint32_t>(random64());
  switch (mode % 10) {
    case 0: return value;
    case 1: return value & 0x807fffffU;
    case 2: return (value & 0x807fffffU) | 0x00800000U;
    case 3: return value & 0x80000000U;
    case 4: return (value & 0x807fffffU) | 0x3f800000U;
    case 5: return (value & 0x807fffffU) | 0x7f000000U;
    case 6: return 0x7f800000U | (value & 0x80000000U);
    case 7: return 0x7fc00000U | (value & 0x803fffffU) | 1U;
    case 8: return 1U | (value & 0x80000000U);
    default: return (value & 0x80000000U) | 0x7f7fffffU;
  }
}

static uint64_t generate64(int mode) {
  const uint64_t value = random64();
  switch (mode % 12) {
    case 0: return value;
    case 1: return value & 0x800fffffffffffffULL;
    case 2: return (value & 0x800fffffffffffffULL) | 0x0010000000000000ULL;
    case 3: return value & 0x8000000000000000ULL;
    case 4: return (value & 0x800fffffffffffffULL) | 0x3ff0000000000000ULL;
    case 5: return (value & 0x800fffffffffffffULL) | 0x47e0000000000000ULL;
    case 6: return (value & 0x800fffffffffffffULL) | 0x3690000000000000ULL;
    case 7: return 0x7ff0000000000000ULL | (value & 0x8000000000000000ULL);
    case 8: return 0x7ff8000000000000ULL | (value & 0x8007ffffffffffffULL) | 1;
    case 9: return 1ULL | (value & 0x8000000000000000ULL);
    case 10: return (value & 0x8000000000000000ULL) | 0x7fefffffffffffffULL;
    default: return (value & 0x800fffffffffffffULL)
        | ((random64() % 0x7feULL) << 52);
  }
}

static int rounding_to_host(int rounding_mode) {
  switch (rounding_mode) {
    case 0: return FE_TONEAREST;
    case 1: return FE_TOWARDZERO;
    case 2: return FE_DOWNWARD;
    case 3: return FE_UPWARD;
    default: return FE_TONEAREST;
  }
}

struct Result {
  uint64_t bits;
  uint8_t flags;
};

static bool is_nan32(uint64_t bits) {
  const uint32_t value = static_cast<uint32_t>(bits);
  return ((value >> 23) & 0xff) == 0xff && (value & 0x007fffffU) != 0;
}

static bool is_nan64(uint64_t bits) {
  return ((bits >> 52) & 0x7ff) == 0x7ff
      && (bits & 0x000fffffffffffffULL) != 0;
}

static Result host_widen(uint64_t operand) {
  Result result{0, 0};
  uint32_t source_bits = static_cast<uint32_t>(operand);
  if ((operand >> 32) != 0xffffffffULL) source_bits = 0x7fc00000U;
  float source;
  double converted;
  memcpy(&source, &source_bits, sizeof(source));
  converted = static_cast<double>(source);
  memcpy(&result.bits, &converted, sizeof(converted));
  if (((source_bits >> 23) & 0xff) == 0xff
      && (source_bits & 0x007fffffU) != 0
      && (source_bits & 0x00400000U) == 0)
    result.flags = 0x10;
  return result;
}

static Result host_narrow(uint64_t operand, int rounding_mode) {
  Result result{0xffffffff00000000ULL, 0};
  double source;
  memcpy(&source, &operand, sizeof(source));
  fesetround(rounding_to_host(rounding_mode));
  feclearexcept(FE_ALL_EXCEPT);
  volatile float converted = static_cast<float>(source);
  uint32_t converted_bits;
  memcpy(&converted_bits, const_cast<const float*>(&converted), sizeof(converted_bits));
  result.bits |= converted_bits;
  const int exceptions = fetestexcept(FE_ALL_EXCEPT);
  if (exceptions & FE_INVALID) result.flags |= 0x10;
  if (exceptions & FE_OVERFLOW) result.flags |= 0x04;
  if (exceptions & FE_UNDERFLOW) result.flags |= 0x02;
  if (exceptions & FE_INEXACT) result.flags |= 0x01;
  fesetround(FE_TONEAREST);
  return result;
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  top = new Vrapt_fpu_convert_tb;
  reset();
  const int iterations = getenv("N") ? atoi(getenv("N")) : 100000;
  int failures = 0;
  int nan_cases = 0;

  for (int iteration = 0; iteration < iterations; ++iteration) {
    const bool narrow = random64() & 1;
    const int rounding_mode = random64() % 4;
    uint64_t operand;
    if (narrow) {
      operand = generate64(random64());
    } else {
      operand = 0xffffffff00000000ULL | generate32(random64());
      if (iteration % 37 == 0) operand &= 0x00000000ffffffffULL;
    }

    top->narrow = narrow;
    top->operand = operand;
    top->rounding_mode = rounding_mode;
    top->valid = 1;
    tick();
    top->valid = 0;
    int cycles = 0;
    while (!top->dut_valid && cycles++ < 10) tick();
    if (!top->dut_valid) {
      if (++failures < 20) printf("TIMEOUT narrow=%d\n", narrow);
      continue;
    }

    const Result expected = narrow
        ? host_narrow(operand, rounding_mode) : host_widen(operand);
    const uint64_t actual_bits = top->dut_result;
    const uint8_t actual_flags = top->dut_flags;
    const bool both_nan = narrow
        ? is_nan32(expected.bits) && is_nan32(actual_bits)
        : is_nan64(expected.bits) && is_nan64(actual_bits);
    if (both_nan) {
      if (expected.flags != actual_flags) {
        if (++failures < 20)
          printf("NAN FLAG narrow=%d rm=%d op=%016llx exp=%02x got=%02x\n",
                 narrow, rounding_mode,
                 static_cast<unsigned long long>(operand),
                 expected.flags, actual_flags);
      } else {
        ++nan_cases;
      }
    } else if (expected.bits != actual_bits || expected.flags != actual_flags) {
      if (++failures < 20)
        printf("MISMATCH narrow=%d rm=%d op=%016llx\n"
               "  host=%016llx f=%02x dut=%016llx f=%02x\n",
               narrow, rounding_mode,
               static_cast<unsigned long long>(operand),
               static_cast<unsigned long long>(expected.bits), expected.flags,
               static_cast<unsigned long long>(actual_bits), actual_flags);
    }
    tick();
  }

  printf("TOTAL=%d FAILS=%d (NaN payload-tolerant, %d NaN cases OK)\n",
         iterations, failures, nan_cases);
  top->final();
  delete top;
  return failures ? 1 : 0;
}

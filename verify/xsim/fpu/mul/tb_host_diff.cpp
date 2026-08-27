#include <cfenv>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "Vrapt_fpu_mul_tb.h"
#include "verilated.h"

static Vrapt_fpu_mul_tb* top;
static uint64_t rng = 0x9e3779b97f4a7c15ULL;

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

static uint64_t generate64(int mode) {
  const uint64_t value = random64();
  switch (mode % 12) {
    case 0: return value;
    case 1: return value & 0x800fffffffffffffULL;
    case 2: return (value & 0x800fffffffffffffULL) | 0x7fe0000000000000ULL;
    case 3: return value & 0x8000000000000000ULL;
    case 4: return (value & 0x800fffffffffffffULL) | 0x3ff0000000000000ULL;
    case 5: return (value & 0x800fffffffffffffULL)
        | ((random64() % 0x7feULL) << 52);
    case 6: return 0x7ff0000000000000ULL | (value & 0x8000000000000000ULL);
    case 7: return 0x7ff8000000000000ULL | (value & 0x8007ffffffffffffULL) | 1;
    case 8: return value & 0x800fffffffffffffULL;
    case 9: return 1ULL | (value & 0x8000000000000000ULL);
    case 10: return (value & 0x800fffffffffffffULL) | 0x0010000000000000ULL;
    default: return (value & 0x8000000000000000ULL) | 0x7fefffffffffffffULL;
  }
}

static uint32_t generate32(int mode) {
  const uint32_t value = static_cast<uint32_t>(random64());
  switch (mode % 12) {
    case 0: return value;
    case 1: return value & 0x807fffffU;
    case 2: return (value & 0x807fffffU) | 0x7f000000U;
    case 3: return value & 0x80000000U;
    case 4: return (value & 0x807fffffU) | 0x3f800000U;
    case 5: return (value & 0x807fffffU)
        | (static_cast<uint32_t>(random64() % 0xfeU) << 23);
    case 6: return 0x7f800000U | (value & 0x80000000U);
    case 7: return 0x7fc00000U | (value & 0x803fffffU) | 1U;
    case 8: return value & 0x807fffffU;
    case 9: return 1U | (value & 0x80000000U);
    case 10: return (value & 0x807fffffU) | 0x00800000U;
    default: return (value & 0x80000000U) | 0x7f7fffffU;
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

static Result host_multiply(uint64_t operand_a, uint64_t operand_b,
                            bool is_double, int rounding_mode) {
  Result result{0, 0};
  if (!is_double
      && ((operand_a >> 32) != 0xffffffffULL
          || (operand_b >> 32) != 0xffffffffULL)) {
    result.bits = 0xffffffff7fc00000ULL;
    return result;
  }

  fesetround(rounding_to_host(rounding_mode));
  feclearexcept(FE_ALL_EXCEPT);
  if (is_double) {
    double lhs, rhs, product;
    memcpy(&lhs, &operand_a, sizeof(lhs));
    memcpy(&rhs, &operand_b, sizeof(rhs));
    product = lhs * rhs;
    memcpy(&result.bits, &product, sizeof(product));
  } else {
    const uint32_t lhs_bits = static_cast<uint32_t>(operand_a);
    const uint32_t rhs_bits = static_cast<uint32_t>(operand_b);
    uint32_t product_bits;
    float lhs, rhs, product;
    memcpy(&lhs, &lhs_bits, sizeof(lhs));
    memcpy(&rhs, &rhs_bits, sizeof(rhs));
    product = lhs * rhs;
    memcpy(&product_bits, &product, sizeof(product));
    result.bits = 0xffffffff00000000ULL | product_bits;
  }
  const int exceptions = fetestexcept(FE_ALL_EXCEPT);
  if (exceptions & FE_INVALID) result.flags |= 0x10;
  if (exceptions & FE_OVERFLOW) result.flags |= 0x04;
  if (exceptions & FE_UNDERFLOW) result.flags |= 0x02;
  if (exceptions & FE_INEXACT) result.flags |= 0x01;
  fesetround(FE_TONEAREST);
  return result;
}

static bool is_nan(uint64_t bits, bool is_double) {
  if (is_double)
    return ((bits >> 52) & 0x7ff) == 0x7ff
        && (bits & 0x000fffffffffffffULL) != 0;
  const uint32_t value = static_cast<uint32_t>(bits);
  return ((value >> 23) & 0xff) == 0xff && (value & 0x007fffffU) != 0;
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  top = new Vrapt_fpu_mul_tb;
  reset();
  const int iterations = getenv("N") ? atoi(getenv("N")) : 100000;
  int failures = 0;
  int nan_cases = 0;

  for (int iteration = 0; iteration < iterations; ++iteration) {
    const bool is_double = random64() & 1;
    const int rounding_mode = random64() % 4;
    uint64_t operand_a, operand_b;
    if (is_double) {
      operand_a = generate64(random64());
      operand_b = generate64(random64());
    } else {
      operand_a = 0xffffffff00000000ULL | generate32(random64());
      operand_b = 0xffffffff00000000ULL | generate32(random64());
      if (iteration % 37 == 0) operand_a &= 0x00000000ffffffffULL;
      if (iteration % 53 == 0) operand_b &= 0x00000000ffffffffULL;
    }

    top->is_double = is_double;
    top->operand_a = operand_a;
    top->operand_b = operand_b;
    top->rounding_mode = rounding_mode;
    top->valid = 1;
    tick();
    top->valid = 0;
    int cycles = 0;
    while (!top->dut_valid && cycles++ < 40) tick();
    if (!top->dut_valid) {
      if (++failures < 20) printf("TIMEOUT\n");
      continue;
    }

    const Result expected = host_multiply(
        operand_a, operand_b, is_double, rounding_mode);
    const uint64_t actual_bits = top->dut_result;
    const uint8_t actual_flags = top->dut_flags;
    if (is_nan(expected.bits, is_double) && is_nan(actual_bits, is_double)) {
      if (expected.flags != actual_flags) {
        if (++failures < 20)
          printf("NAN FLAG dbl=%d rm=%d a=%016llx b=%016llx exp=%02x got=%02x\n",
                 is_double, rounding_mode,
                 static_cast<unsigned long long>(operand_a),
                 static_cast<unsigned long long>(operand_b),
                 expected.flags, actual_flags);
      } else {
        ++nan_cases;
      }
    } else if (expected.bits != actual_bits || expected.flags != actual_flags) {
      if (++failures < 20)
        printf("MISMATCH dbl=%d rm=%d a=%016llx b=%016llx\n"
               "  host=%016llx f=%02x dut=%016llx f=%02x\n",
               is_double, rounding_mode,
               static_cast<unsigned long long>(operand_a),
               static_cast<unsigned long long>(operand_b),
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
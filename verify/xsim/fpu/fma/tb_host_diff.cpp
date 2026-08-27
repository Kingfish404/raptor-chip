#include <cfenv>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include "Vrapt_fpu_fma_tb.h"
#include "verilated.h"

#pragma STDC FENV_ACCESS ON

static Vrapt_fpu_fma_tb *top;
static uint64_t random_state = 0x6a09e667f3bcc909ULL;
static uint64_t random64() {
  random_state ^= random_state << 13;
  random_state ^= random_state >> 7;
  random_state ^= random_state << 17;
  return random_state;
}
static void tick() { top->clock = 0; top->eval(); top->clock = 1; top->eval(); }
static void reset() {
  top->reset = 1; top->valid = 0; top->flush = 0;
  for (int index = 0; index < 4; ++index) tick();
  top->reset = 0; tick();
}
static int rounding_to_host(int rounding) {
  static const int modes[] = {FE_TONEAREST, FE_TOWARDZERO, FE_DOWNWARD, FE_UPWARD};
  return modes[rounding];
}
static uint64_t generate_value(int mode) {
  uint64_t value = random64();
  switch (mode % 12) {
    case 0: return value;
    case 1: return value & 0x800fffffffffffffULL;
    case 2: return (value & 0x800fffffffffffffULL) | 0x7fe0000000000000ULL;
    case 3: return value & 0x8000000000000000ULL;
    case 4: return (value & 0x800fffffffffffffULL) | 0x3ff0000000000000ULL;
    case 5: return (value & 0x800fffffffffffffULL) | ((random64() % 0x7fe) << 52);
    case 6: return 0x7ff0000000000000ULL | (value & 0x8000000000000000ULL);
    case 7: return 0x7ff8000000000000ULL | (value & 0x8007ffffffffffffULL) | 1;
    case 8: return value & 0x800fffffffffffffULL;
    case 9: return 1 | (value & 0x8000000000000000ULL);
    case 10: return (value & 0x800fffffffffffffULL) | 0x0010000000000000ULL;
    default: return (value & 0x8000000000000000ULL) | 0x7fefffffffffffffULL;
  }
}
struct Reference { uint64_t bits; uint8_t flags; };
static Reference reference(uint64_t a_bits, uint64_t b_bits, uint64_t c_bits,
                           bool is_double, int variant, int rounding) {
  fesetround(rounding_to_host(rounding));
  feclearexcept(FE_ALL_EXCEPT);
  Reference result{0, 0};
  if (is_double) {
    double a, b, c;
    memcpy(&a, &a_bits, 8); memcpy(&b, &b_bits, 8); memcpy(&c, &c_bits, 8);
    if (variant >= 2) a = -a;
    if (variant == 1 || variant == 3) c = -c;
    double value = std::fma(a, b, c);
    memcpy(&result.bits, &value, 8);
  } else {
    uint32_t raw_a = a_bits, raw_b = b_bits, raw_c = c_bits;
    float a, b, c;
    memcpy(&a, &raw_a, 4); memcpy(&b, &raw_b, 4); memcpy(&c, &raw_c, 4);
    if (variant >= 2) a = -a;
    if (variant == 1 || variant == 3) c = -c;
    float value = std::fma(a, b, c);
    uint32_t raw_result; memcpy(&raw_result, &value, 4);
    result.bits = 0xffffffff00000000ULL | raw_result;
  }
  int exceptions = fetestexcept(FE_ALL_EXCEPT);
  if (exceptions & FE_INVALID) result.flags |= 0x10;
  if (exceptions & FE_OVERFLOW) result.flags |= 0x04;
  if (exceptions & FE_UNDERFLOW) result.flags |= 0x02;
  if (exceptions & FE_INEXACT) result.flags |= 0x01;
  fesetround(FE_TONEAREST);
  return result;
}
static bool is_nan(uint64_t bits, bool is_double) {
  if (is_double) return ((bits >> 52) & 0x7ff) == 0x7ff && (bits & 0xfffffffffffffULL);
  uint32_t value = bits;
  return ((value >> 23) & 0xff) == 0xff && (value & 0x7fffff);
}
static bool is_zero(uint64_t bits, bool is_double) {
  return is_double ? (bits & 0x7fffffffffffffffULL) == 0
                   : (uint32_t(bits) & 0x7fffffffU) == 0;
}
static bool is_infinity(uint64_t bits, bool is_double) {
  return is_double ? (bits & 0x7fffffffffffffffULL) == 0x7ff0000000000000ULL
                   : (uint32_t(bits) & 0x7fffffffU) == 0x7f800000U;
}
int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv); top = new Vrapt_fpu_fma_tb; reset();
  int iterations = getenv("N") ? atoi(getenv("N")) : 200000;
  int failures = 0, nan_cases = 0;
  for (int index = 0; index < iterations; ++index) {
    bool is_double = random64() & 1; int variant = random64() % 4;
    int rounding = random64() % 4;
    uint64_t a = generate_value(random64()), b = generate_value(random64());
    uint64_t c = generate_value(random64());
    if (!is_double) {
      a = 0xffffffff00000000ULL | uint32_t(a);
      b = 0xffffffff00000000ULL | uint32_t(b);
      c = 0xffffffff00000000ULL | uint32_t(c);
    }
    top->is_double = is_double; top->op = 51 + is_double + variant * 2;
    top->operand_a = a; top->operand_b = b; top->operand_c = c;
    top->rounding_mode = rounding; top->valid = 1; tick(); top->valid = 0;
    if ((index % 997) == 0) {
      top->flush = 1; tick(); top->flush = 0;
      for (int cycle = 0; cycle < 8; ++cycle) {
        tick();
        if (top->dut_valid) { ++failures; printf("STALE RESULT AFTER FLUSH\n"); break; }
      }
      continue;
    }
    int cycles = 0; while (!top->dut_valid && cycles++ < 20) tick();
    if (!top->dut_valid) { ++failures; printf("TIMEOUT\n"); continue; }
    Reference expected = reference(a, b, c, is_double, variant, rounding);
    if ((is_zero(a, is_double) && is_infinity(b, is_double))
        || (is_infinity(a, is_double) && is_zero(b, is_double)))
      expected.flags |= 0x10;
    bool expected_nan = is_nan(expected.bits, is_double);
    bool actual_nan = is_nan(top->dut_result, is_double);
    if (expected_nan && actual_nan) {
      if (expected.flags != top->dut_flags) {
        if (++failures < 20)
          printf("NaN FLAG d=%d op=%d rm=%d a=%016llx b=%016llx c=%016llx exp=%02x got=%02x\n",
                 is_double, variant, rounding, (unsigned long long)a,
                 (unsigned long long)b, (unsigned long long)c,
                 expected.flags, top->dut_flags);
      } else ++nan_cases;
    } else if (expected.bits != top->dut_result || expected.flags != top->dut_flags) {
      if (++failures < 20)
        printf("MISMATCH d=%d op=%d rm=%d a=%016llx b=%016llx c=%016llx exp=%016llx/%02x got=%016llx/%02x\n",
               is_double, variant, rounding, (unsigned long long)a,
               (unsigned long long)b, (unsigned long long)c,
               (unsigned long long)expected.bits, expected.flags,
               (unsigned long long)top->dut_result, top->dut_flags);
    }
    tick();
  }
  printf("TOTAL=%d FAILS=%d (NaN payload-tolerant, %d NaN cases OK)\n",
         iterations, failures, nan_cases);
  top->final(); delete top; return failures != 0;
}

#include <cfenv>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "Vrapt_fpu_int_to_fp_tb.h"
#include "verilated.h"

static Vrapt_fpu_int_to_fp_tb* top;
static uint64_t rng = 0x13198a2e03707344ULL;

static uint64_t random64() {
  rng ^= rng << 13;
  rng ^= rng >> 7;
  rng ^= rng << 17;
  return rng;
}

static void tick() {
  top->clock = 0; top->eval();
  top->clock = 1; top->eval();
}

static int host_rounding(int mode) {
  static const int modes[] = {FE_TONEAREST, FE_TOWARDZERO, FE_DOWNWARD, FE_UPWARD};
  return modes[mode];
}

struct Result { uint64_t bits; uint8_t flags; };

static Result reference(uint64_t operand, bool target_double, bool int64_input,
                        bool unsigned_input, int rounding_mode) {
  Result result{target_double ? 0ULL : 0xffffffff00000000ULL, 0};
  fesetround(host_rounding(rounding_mode));
  feclearexcept(FE_ALL_EXCEPT);
  if (target_double) {
    volatile double converted;
    if (int64_input)
      converted = unsigned_input ? static_cast<double>(operand)
          : static_cast<double>(static_cast<int64_t>(operand));
    else
      converted = unsigned_input ? static_cast<double>(static_cast<uint32_t>(operand))
          : static_cast<double>(static_cast<int32_t>(operand));
    memcpy(&result.bits, const_cast<const double*>(&converted), sizeof(converted));
  } else {
    volatile float converted;
    if (int64_input)
      converted = unsigned_input ? static_cast<float>(operand)
          : static_cast<float>(static_cast<int64_t>(operand));
    else
      converted = unsigned_input ? static_cast<float>(static_cast<uint32_t>(operand))
          : static_cast<float>(static_cast<int32_t>(operand));
    uint32_t bits;
    memcpy(&bits, const_cast<const float*>(&converted), sizeof(converted));
    result.bits |= bits;
  }
  if (fetestexcept(FE_INEXACT)) result.flags = 1;
  fesetround(FE_TONEAREST);
  return result;
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  top = new Vrapt_fpu_int_to_fp_tb;
  top->reset = 1; top->valid = 0; top->flush = 0;
  for (int index = 0; index < 4; ++index) tick();
  top->reset = 0; tick();

  const int iterations = getenv("N") ? atoi(getenv("N")) : 100000;
  int failures = 0;
  for (int iteration = 0; iteration < iterations; ++iteration) {
    uint64_t operand = random64();
    if (iteration < 8) {
      static const uint64_t corners[] = {0, 1, ~0ULL, 0x8000000000000000ULL,
          0x7fffffffffffffffULL, 0x01000001ULL, 0x100000001ULL, 0xffffffffULL};
      operand = corners[iteration];
    }
    const bool target_double = random64() & 1;
    const bool int64_input = random64() & 1;
    const bool unsigned_input = random64() & 1;
    const int rounding_mode = random64() % 4;

    top->target_double = target_double;
    top->int64_input = int64_input;
    top->unsigned_input = unsigned_input;
    top->operand = operand;
    top->rounding_mode = rounding_mode;
    top->valid = 1; tick(); top->valid = 0;
    int cycles = 0;
    while (!top->dut_valid && cycles++ < 10) tick();
    if (!top->dut_valid) {
      if (++failures < 20) printf("TIMEOUT\n");
      continue;
    }

    const Result expected = reference(operand, target_double, int64_input,
                                      unsigned_input, rounding_mode);
    if (expected.bits != top->dut_result || expected.flags != top->dut_flags) {
      if (++failures < 20)
        printf("MISMATCH d=%d l=%d u=%d rm=%d op=%016llx\n"
               " host=%016llx f=%02x dut=%016llx f=%02x\n",
               target_double, int64_input, unsigned_input, rounding_mode,
               static_cast<unsigned long long>(operand),
               static_cast<unsigned long long>(expected.bits), expected.flags,
               static_cast<unsigned long long>(top->dut_result), top->dut_flags);
    }
    tick();
  }
  printf("TOTAL=%d FAILS=%d\n", iterations, failures);
  top->final(); delete top;
  return failures ? 1 : 0;
}

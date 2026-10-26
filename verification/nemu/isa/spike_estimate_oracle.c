#include <stdint.h>
#include "softfloat/softfloat.h"

typedef struct {
  uint64_t bits;
  uint32_t flags;
} estimate_result;

estimate_result estimate_oracle(uint64_t operand, int bytes, int reciprocal_sqrt, int rounding)
{
  softfloat_roundingMode = rounding;
  softfloat_exceptionFlags = 0;
  uint64_t result;
  if (bytes == 4) {
    float32_t input = {.v = (uint32_t)operand};
    float32_t output = reciprocal_sqrt ? f32_rsqrte7(input) : f32_recip7(input);
    result = output.v;
  } else {
    float64_t input = {.v = operand};
    float64_t output = reciprocal_sqrt ? f64_rsqrte7(input) : f64_recip7(input);
    result = output.v;
  }
  return (estimate_result){.bits = result, .flags = softfloat_exceptionFlags};
}

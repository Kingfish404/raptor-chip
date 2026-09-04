#include "local-include/fp.h"
#include <stdbool.h>
#include <softfloat.h>

static uint_fast8_t riscv_fp_rounding_mode(unsigned rm)
{
  switch (rm & 0x7) {
  case 0: return softfloat_round_near_even;
  case 1: return softfloat_round_minMag;
  case 2: return softfloat_round_min;
  case 3: return softfloat_round_max;
  case 4: return softfloat_round_near_maxMag;
  default: return softfloat_round_near_even;
  }
}

static uint32_t riscv_fp_flags(void)
{
  uint_fast8_t sf = softfloat_exceptionFlags;
  uint32_t flags = 0;
  if (sf & softfloat_flag_invalid) flags |= 1u << 4;
  if (sf & softfloat_flag_infinite) flags |= 1u << 3;
  if (sf & softfloat_flag_overflow) flags |= 1u << 2;
  if (sf & softfloat_flag_underflow) flags |= 1u << 1;
  if (sf & softfloat_flag_inexact) flags |= 1u << 0;
  return flags;
}

static uint64_t riscv_fp_binary_d(uint64_t lhs, uint64_t rhs, unsigned rm,
                                  float64_t (*operation)(float64_t, float64_t),
                                  uint32_t *flags)
{
  softfloat_roundingMode = riscv_fp_rounding_mode(rm);
  softfloat_exceptionFlags = 0;
  float64_t result = operation((float64_t){lhs}, (float64_t){rhs});
  *flags = riscv_fp_flags();
  return result.v;
}

static uint32_t riscv_fp_binary_s(uint32_t lhs, uint32_t rhs, unsigned rm,
                                  float32_t (*operation)(float32_t, float32_t),
                                  uint32_t *flags)
{
  softfloat_roundingMode = riscv_fp_rounding_mode(rm);
  softfloat_exceptionFlags = 0;
  float32_t result = operation((float32_t){lhs}, (float32_t){rhs});
  *flags = riscv_fp_flags();
  return result.v;
}

static uint32_t riscv_fp_unary_s(uint32_t operand, unsigned rm,
                                 float32_t (*operation)(float32_t),
                                 uint32_t *flags)
{
  softfloat_roundingMode = riscv_fp_rounding_mode(rm);
  softfloat_exceptionFlags = 0;
  float32_t result = operation((float32_t){operand});
  *flags = riscv_fp_flags();
  return result.v;
}

uint32_t riscv_fp_add_s(uint32_t lhs, uint32_t rhs, unsigned rm, uint32_t *flags)
{
  return riscv_fp_binary_s(lhs, rhs, rm, f32_add, flags);
}

uint32_t riscv_fp_sub_s(uint32_t lhs, uint32_t rhs, unsigned rm, uint32_t *flags)
{
  return riscv_fp_binary_s(lhs, rhs, rm, f32_sub, flags);
}

uint32_t riscv_fp_mul_s(uint32_t lhs, uint32_t rhs, unsigned rm, uint32_t *flags)
{
  return riscv_fp_binary_s(lhs, rhs, rm, f32_mul, flags);
}

uint32_t riscv_fp_div_s(uint32_t lhs, uint32_t rhs, unsigned rm, uint32_t *flags)
{
  return riscv_fp_binary_s(lhs, rhs, rm, f32_div, flags);
}

uint32_t riscv_fp_sqrt_s(uint32_t operand, unsigned rm, uint32_t *flags)
{
  return riscv_fp_unary_s(operand, rm, f32_sqrt, flags);
}

uint32_t riscv_fp_fma_s(uint32_t lhs, uint32_t rhs, uint32_t addend, unsigned rm,
                        bool negate_product, bool negate_addend, uint32_t *flags)
{
  softfloat_roundingMode = riscv_fp_rounding_mode(rm);
  softfloat_exceptionFlags = 0;
  if (negate_product) lhs ^= UINT32_C(0x80000000);
  if (negate_addend) addend ^= UINT32_C(0x80000000);
  float32_t result = f32_mulAdd((float32_t){lhs}, (float32_t){rhs},
                                (float32_t){addend});
  *flags = riscv_fp_flags();
  return result.v;
}

static bool riscv_fp_is_nan_s(uint32_t bits)
{
  return (bits & UINT32_C(0x7f800000)) == UINT32_C(0x7f800000)
      && (bits & UINT32_C(0x007fffff)) != 0;
}

static bool riscv_fp_is_snan_s(uint32_t bits)
{
  return riscv_fp_is_nan_s(bits) && (bits & UINT32_C(0x00400000)) == 0;
}

static bool riscv_fp_less_s(uint32_t lhs, uint32_t rhs)
{
  bool lhs_sign = (lhs >> 31) != 0;
  bool rhs_sign = (rhs >> 31) != 0;
  if (lhs_sign != rhs_sign)
    return lhs_sign;
  return lhs_sign ? lhs > rhs : lhs < rhs;
}

static uint32_t riscv_fp_minmax_s(uint32_t lhs, uint32_t rhs, bool maximum,
                                   uint32_t *flags)
{
  bool lhs_nan = riscv_fp_is_nan_s(lhs);
  bool rhs_nan = riscv_fp_is_nan_s(rhs);
  *flags = (riscv_fp_is_snan_s(lhs) || riscv_fp_is_snan_s(rhs)) ? (1u << 4) : 0;
  if (lhs_nan && rhs_nan)
    return UINT32_C(0x7fc00000);
  if (lhs_nan)
    return rhs;
  if (rhs_nan)
    return lhs;
  if (((lhs | rhs) << 1) == 0)
    return maximum ? (lhs & rhs) : (lhs | rhs);
  bool lhs_less = riscv_fp_less_s(lhs, rhs);
  return maximum ? (lhs_less ? rhs : lhs) : (lhs_less ? lhs : rhs);
}

uint32_t riscv_fp_min_s(uint32_t lhs, uint32_t rhs, uint32_t *flags)
{
  return riscv_fp_minmax_s(lhs, rhs, false, flags);
}

uint32_t riscv_fp_max_s(uint32_t lhs, uint32_t rhs, uint32_t *flags)
{
  return riscv_fp_minmax_s(lhs, rhs, true, flags);
}

static uint32_t riscv_fp_compare_s(uint32_t lhs, uint32_t rhs, unsigned mode,
                                   uint32_t *flags)
{
  float32_t lhs_float = {lhs};
  float32_t rhs_float = {rhs};
  bool result;
  softfloat_exceptionFlags = 0;
  switch (mode) {
  case 0: result = f32_le(lhs_float, rhs_float); break;
  case 1: result = f32_lt(lhs_float, rhs_float); break;
  default: result = f32_eq(lhs_float, rhs_float); break;
  }
  *flags = riscv_fp_flags();
  return result;
}

uint32_t riscv_fp_le_s(uint32_t lhs, uint32_t rhs, uint32_t *flags)
{
  return riscv_fp_compare_s(lhs, rhs, 0, flags);
}

uint32_t riscv_fp_lt_s(uint32_t lhs, uint32_t rhs, uint32_t *flags)
{
  return riscv_fp_compare_s(lhs, rhs, 1, flags);
}

uint32_t riscv_fp_eq_s(uint32_t lhs, uint32_t rhs, uint32_t *flags)
{
  return riscv_fp_compare_s(lhs, rhs, 2, flags);
}

uint32_t riscv_fp_class_s(uint32_t bits)
{
  uint32_t exponent = bits & UINT32_C(0x7f800000);
  uint32_t fraction = bits & UINT32_C(0x007fffff);
  bool negative = (bits >> 31) != 0;
  if (exponent == UINT32_C(0x7f800000)) {
    if (fraction == 0) return 1u << (negative ? 0 : 7);
    return 1u << ((fraction & UINT32_C(0x00400000)) ? 9 : 8);
  }
  if (exponent == 0) {
    if (fraction == 0) return 1u << (negative ? 3 : 4);
    return 1u << (negative ? 2 : 5);
  }
  return 1u << (negative ? 1 : 6);
}

uint64_t riscv_fp_add_d(uint64_t lhs, uint64_t rhs, unsigned rm, uint32_t *flags)
{
  return riscv_fp_binary_d(lhs, rhs, rm, f64_add, flags);
}

uint64_t riscv_fp_sub_d(uint64_t lhs, uint64_t rhs, unsigned rm, uint32_t *flags)
{
  return riscv_fp_binary_d(lhs, rhs, rm, f64_sub, flags);
}

uint64_t riscv_fp_mul_d(uint64_t lhs, uint64_t rhs, unsigned rm, uint32_t *flags)
{
  return riscv_fp_binary_d(lhs, rhs, rm, f64_mul, flags);
}

uint64_t riscv_fp_div_d(uint64_t lhs, uint64_t rhs, unsigned rm, uint32_t *flags)
{
  return riscv_fp_binary_d(lhs, rhs, rm, f64_div, flags);
}

static uint64_t riscv_fp_unary_d(uint64_t operand, unsigned rm,
                                 float64_t (*operation)(float64_t),
                                 uint32_t *flags)
{
  softfloat_roundingMode = riscv_fp_rounding_mode(rm);
  softfloat_exceptionFlags = 0;
  float64_t result = operation((float64_t){operand});
  *flags = riscv_fp_flags();
  return result.v;
}

uint64_t riscv_fp_sqrt_d(uint64_t operand, unsigned rm, uint32_t *flags)
{
  return riscv_fp_unary_d(operand, rm, f64_sqrt, flags);
}

uint64_t riscv_fp_fma_d(uint64_t lhs, uint64_t rhs, uint64_t addend, unsigned rm,
                        bool negate_product, bool negate_addend, uint32_t *flags)
{
  softfloat_roundingMode = riscv_fp_rounding_mode(rm);
  softfloat_exceptionFlags = 0;
  if (negate_product) lhs ^= UINT64_C(0x8000000000000000);
  if (negate_addend) addend ^= UINT64_C(0x8000000000000000);
  float64_t result = f64_mulAdd((float64_t){lhs}, (float64_t){rhs},
                                (float64_t){addend});
  *flags = riscv_fp_flags();
  return result.v;
}

static bool riscv_fp_is_nan_d(uint64_t bits)
{
  return (bits & UINT64_C(0x7ff0000000000000)) == UINT64_C(0x7ff0000000000000)
      && (bits & UINT64_C(0x000fffffffffffff)) != 0;
}

static bool riscv_fp_is_snan_d(uint64_t bits)
{
  return riscv_fp_is_nan_d(bits) && (bits & UINT64_C(0x0008000000000000)) == 0;
}

static bool riscv_fp_less_d(uint64_t lhs, uint64_t rhs)
{
  bool lhs_sign = (lhs >> 63) != 0;
  bool rhs_sign = (rhs >> 63) != 0;
  if (lhs_sign != rhs_sign)
    return lhs_sign;
  return lhs_sign ? lhs > rhs : lhs < rhs;
}

static uint64_t riscv_fp_minmax_d(uint64_t lhs, uint64_t rhs, bool maximum,
                                   uint32_t *flags)
{
  bool lhs_nan = riscv_fp_is_nan_d(lhs);
  bool rhs_nan = riscv_fp_is_nan_d(rhs);
  *flags = (riscv_fp_is_snan_d(lhs) || riscv_fp_is_snan_d(rhs)) ? (1u << 4) : 0;
  if (lhs_nan && rhs_nan)
    return UINT64_C(0x7ff8000000000000);
  if (lhs_nan)
    return rhs;
  if (rhs_nan)
    return lhs;
  if (((lhs | rhs) << 1) == 0)
    return maximum ? (lhs & rhs) : (lhs | rhs);
  bool lhs_less = riscv_fp_less_d(lhs, rhs);
  return maximum ? (lhs_less ? rhs : lhs) : (lhs_less ? lhs : rhs);
}

uint64_t riscv_fp_min_d(uint64_t lhs, uint64_t rhs, uint32_t *flags)
{
  return riscv_fp_minmax_d(lhs, rhs, false, flags);
}

uint64_t riscv_fp_max_d(uint64_t lhs, uint64_t rhs, uint32_t *flags)
{
  return riscv_fp_minmax_d(lhs, rhs, true, flags);
}

static uint32_t riscv_fp_compare_d(uint64_t lhs, uint64_t rhs, unsigned mode,
                                   uint32_t *flags)
{
  float64_t lhs_float = {lhs};
  float64_t rhs_float = {rhs};
  bool result;
  softfloat_exceptionFlags = 0;
  switch (mode) {
  case 0: result = f64_le(lhs_float, rhs_float); break;
  case 1: result = f64_lt(lhs_float, rhs_float); break;
  default: result = f64_eq(lhs_float, rhs_float); break;
  }
  *flags = riscv_fp_flags();
  return result;
}

uint32_t riscv_fp_le_d(uint64_t lhs, uint64_t rhs, uint32_t *flags)
{
  return riscv_fp_compare_d(lhs, rhs, 0, flags);
}

uint32_t riscv_fp_lt_d(uint64_t lhs, uint64_t rhs, uint32_t *flags)
{
  return riscv_fp_compare_d(lhs, rhs, 1, flags);
}

uint32_t riscv_fp_eq_d(uint64_t lhs, uint64_t rhs, uint32_t *flags)
{
  return riscv_fp_compare_d(lhs, rhs, 2, flags);
}

uint32_t riscv_fp_class_d(uint64_t bits)
{
  uint64_t exponent = bits & UINT64_C(0x7ff0000000000000);
  uint64_t fraction = bits & UINT64_C(0x000fffffffffffff);
  bool negative = (bits >> 63) != 0;
  if (exponent == UINT64_C(0x7ff0000000000000)) {
    if (fraction == 0) return 1u << (negative ? 0 : 7);
    return 1u << ((fraction & UINT64_C(0x0008000000000000)) ? 9 : 8);
  }
  if (exponent == 0) {
    if (fraction == 0) return 1u << (negative ? 3 : 4);
    return 1u << (negative ? 2 : 5);
  }
  return 1u << (negative ? 1 : 6);
}

uint64_t riscv_fp_to_int_s(uint32_t bits, unsigned rm, bool unsigned_result,
                           bool int64, uint32_t *flags)
{
  float32_t input = {bits};
  uint64_t result;
  softfloat_roundingMode = riscv_fp_rounding_mode(rm);
  softfloat_exceptionFlags = 0;
  if (int64) {
    result = unsigned_result ? (uint64_t)f32_to_ui64(input, softfloat_roundingMode, true)
                             : (uint64_t)(int64_t)f32_to_i64(input, softfloat_roundingMode, true);
  } else {
    result = unsigned_result ? (uint32_t)f32_to_ui32(input, softfloat_roundingMode, true)
                             : (uint32_t)(int32_t)f32_to_i32(input, softfloat_roundingMode, true);
  }
  *flags = riscv_fp_flags();
  return result;
}

uint64_t riscv_fp_to_int_d(uint64_t bits, unsigned rm, bool unsigned_result,
                           bool int64, uint32_t *flags)
{
  float64_t input = {bits};
  uint64_t result;
  softfloat_roundingMode = riscv_fp_rounding_mode(rm);
  softfloat_exceptionFlags = 0;
  if (int64) {
    result = unsigned_result ? (uint64_t)f64_to_ui64(input, softfloat_roundingMode, true)
                             : (uint64_t)(int64_t)f64_to_i64(input, softfloat_roundingMode, true);
  } else {
    result = unsigned_result ? (uint32_t)f64_to_ui32(input, softfloat_roundingMode, true)
                             : (uint32_t)(int32_t)f64_to_i32(input, softfloat_roundingMode, true);
  }
  *flags = riscv_fp_flags();
  return result;
}

uint32_t riscv_int_to_fp_s(uint64_t value, unsigned rm, bool unsigned_input,
                           bool int64, uint32_t *flags)
{
  float32_t result;
  softfloat_roundingMode = riscv_fp_rounding_mode(rm);
  softfloat_exceptionFlags = 0;
  if (int64) {
    result = unsigned_input ? ui64_to_f32(value) : i64_to_f32((int64_t)value);
  } else {
    result = unsigned_input ? ui32_to_f32((uint32_t)value) : i32_to_f32((int32_t)value);
  }
  *flags = riscv_fp_flags();
  return result.v;
}

uint64_t riscv_int_to_fp_d(uint64_t value, unsigned rm, bool unsigned_input,
                           bool int64, uint32_t *flags)
{
  float64_t result;
  softfloat_roundingMode = riscv_fp_rounding_mode(rm);
  softfloat_exceptionFlags = 0;
  if (int64) {
    result = unsigned_input ? ui64_to_f64(value) : i64_to_f64((int64_t)value);
  } else {
    result = unsigned_input ? ui32_to_f64((uint32_t)value) : i32_to_f64((int32_t)value);
  }
  *flags = riscv_fp_flags();
  return result.v;
}

uint32_t riscv_fp_convert_d_to_s(uint64_t bits, unsigned rm, uint32_t *flags)
{
  softfloat_roundingMode = riscv_fp_rounding_mode(rm);
  softfloat_exceptionFlags = 0;
  float32_t result = f64_to_f32((float64_t){bits});
  *flags = riscv_fp_flags();
  return result.v;
}

uint64_t riscv_fp_convert_s_to_d(uint32_t bits, unsigned rm, uint32_t *flags)
{
  softfloat_roundingMode = riscv_fp_rounding_mode(rm);
  softfloat_exceptionFlags = 0;
  float64_t result = f32_to_f64((float32_t){bits});
  *flags = riscv_fp_flags();
  return result.v;
}

uint64_t riscv_fp_box_s(uint32_t bits)
{
  return UINT64_C(0xffffffff00000000) | bits;
}

uint64_t riscv_fp_box_h(uint16_t bits)
{
  return UINT64_C(0xffffffffffff0000) | bits;
}

uint32_t riscv_fp_s_bits(uint64_t bits)
{
  return (uint32_t)bits;
}

uint16_t riscv_fp_h_bits(uint64_t bits)
{
  return (uint16_t)bits;
}

uint32_t riscv_fp_read_s(uint64_t bits)
{
  return (bits >> 32) == UINT32_MAX ? (uint32_t)bits : UINT32_C(0x7fc00000);
}

uint16_t riscv_fp_read_h(uint64_t bits)
{
  return (bits >> 16) == UINT64_C(0x0000ffffffffffff)
      ? (uint16_t)bits : UINT16_C(0x7e00);
}

static bool riscv_fp_is_nan_h(uint16_t bits)
{
  return (bits & UINT16_C(0x7c00)) == UINT16_C(0x7c00)
      && (bits & UINT16_C(0x03ff)) != 0;
}

uint32_t riscv_fp_convert_h_to_s(uint16_t bits, uint32_t *flags)
{
  softfloat_exceptionFlags = 0;
  if (riscv_fp_is_nan_h(bits)) {
    *flags = (bits & UINT16_C(0x0200)) ? 0 : (1u << 4);
    return UINT32_C(0x7fc00000);
  }
  float32_t result = f16_to_f32((float16_t){bits});
  *flags = riscv_fp_flags();
  return result.v;
}

uint64_t riscv_fp_convert_h_to_d(uint16_t bits, uint32_t *flags)
{
  softfloat_exceptionFlags = 0;
  if (riscv_fp_is_nan_h(bits)) {
    *flags = (bits & UINT16_C(0x0200)) ? 0 : (1u << 4);
    return UINT64_C(0x7ff8000000000000);
  }
  float64_t result = f16_to_f64((float16_t){bits});
  *flags = riscv_fp_flags();
  return result.v;
}

uint16_t riscv_fp_convert_s_to_h(uint32_t bits, unsigned rm, uint32_t *flags)
{
  bool nan = (bits & UINT32_C(0x7f800000)) == UINT32_C(0x7f800000)
      && (bits & UINT32_C(0x007fffff)) != 0;
  if (nan) {
    *flags = (bits & UINT32_C(0x00400000)) ? 0 : (1u << 4);
    return UINT16_C(0x7e00);
  }
  softfloat_roundingMode = riscv_fp_rounding_mode(rm);
  softfloat_exceptionFlags = 0;
  float16_t result = f32_to_f16((float32_t){bits});
  *flags = riscv_fp_flags();
  return result.v;
}

uint16_t riscv_fp_convert_d_to_h(uint64_t bits, unsigned rm, uint32_t *flags)
{
  bool nan = (bits & UINT64_C(0x7ff0000000000000)) == UINT64_C(0x7ff0000000000000)
      && (bits & UINT64_C(0x000fffffffffffff)) != 0;
  if (nan) {
    *flags = (bits & UINT64_C(0x0008000000000000)) ? 0 : (1u << 4);
    return UINT16_C(0x7e00);
  }
  softfloat_roundingMode = riscv_fp_rounding_mode(rm);
  softfloat_exceptionFlags = 0;
  float16_t result = f64_to_f16((float64_t){bits});
  *flags = riscv_fp_flags();
  return result.v;
}

uint64_t riscv_fp_sgnj(uint64_t lhs, uint64_t rhs, unsigned mode)
{
  uint32_t lhs_bits = riscv_fp_read_s(lhs);
  uint32_t rhs_bits = riscv_fp_read_s(rhs);
  uint64_t sign = rhs_bits & UINT64_C(0x80000000);
  if (mode == 1)
    sign = (~rhs_bits) & UINT64_C(0x80000000);
  else if (mode == 2)
    sign = (lhs_bits ^ rhs_bits) & UINT64_C(0x80000000);
  return riscv_fp_box_s((uint32_t)((lhs_bits & UINT64_C(0x7fffffff)) | sign));
}

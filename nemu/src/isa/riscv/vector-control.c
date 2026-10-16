#include <isa-def.h>
#include <vector-control.h>
#include <cpu/thread.h>
#include <memory/trap.h>
#include <memory/vaddr.h>
#include "local-include/fp.h"

extern NEMU_TLS word_t g_vaddr;

static unsigned vector_vlmax(word_t vtype)
{
  if (vtype & ~(word_t)0xff) return 0;
  unsigned sew = (vtype >> 3) & 7;
  unsigned encoded_lmul = vtype & 7;
  if (sew > 3 || encoded_lmul == 4) return 0;
  int lmul = encoded_lmul < 4 ? (int)encoded_lmul : (int)encoded_lmul - 8;
  if ((8u << sew) > (lmul >= 0 ? 64u << lmul : 64u >> -lmul)) return 0;
  unsigned elements = 128u / (8u << sew);
  return lmul >= 0 ? elements << lmul : elements >> -lmul;
}

void riscv_vector_reset(void)
{
  if (!riscv_v128_preview_enabled()) return;
  memset(cpu.vreg, 0, sizeof(cpu.vreg));
  cpu.sr[CSR_VTYPE] = (word_t)1 << (XLEN - 1);
  cpu.sr[CSR_VL] = 0;
  cpu.sr[CSR_VLENB] = 16;
  cpu.sr[CSR_VSTART] = 0;
  cpu.sr[CSR_VXRM] = 0;
  cpu.sr[CSR_VXSAT] = 0;
  cpu.sr[CSR_VCSR] = 0;
}

bool riscv_vector_context_enabled(void)
{
  return riscv_v128_preview_enabled() &&
      (cpu.sr[CSR_MSTATUS] & CSR_MSTATUS_VS_MASK) &&
      (!cpu.virt || (cpu.sr[CSR_VSSTATUS] & CSR_MSTATUS_VS_MASK));
}

static bool vector_fp_context_enabled(void)
{
  return (cpu.sr[CSR_MSTATUS] & CSR_MSTATUS_FS_MASK) &&
      (!cpu.virt || (cpu.sr[CSR_VSSTATUS] & CSR_MSTATUS_FS_MASK));
}

static void vector_mark_dirty(bool floating)
{
  cpu.sr[CSR_MSTATUS] |= CSR_MSTATUS_VS_MASK;
  if (floating) cpu.sr[CSR_MSTATUS] |= CSR_MSTATUS_FS_MASK;
  if (cpu.virt)
  {
    cpu.sr[CSR_VSSTATUS] |= CSR_MSTATUS_VS_MASK;
    if (floating) cpu.sr[CSR_VSSTATUS] |= CSR_MSTATUS_FS_MASK;
  }
}

bool riscv_vector_configure(uint32_t instruction)
{
  if (!riscv_vector_context_enabled())
    return false;
  unsigned rd = (instruction >> 7) & 31;
  unsigned rs1 = (instruction >> 15) & 31;
  word_t requested;
  bool immediate_avl = false;
  if (!(instruction & (1u << 31)))
    requested = (instruction >> 20) & 0x7ff;
  else if ((instruction >> 30) == 3)
  {
    requested = (instruction >> 20) & 0x3ff;
    immediate_avl = true;
  }
  else if ((instruction >> 25) == 0x40)
    requested = cpu.gpr[(instruction >> 20) & 31];
  else
    return false;

  unsigned maximum = vector_vlmax(requested);
  bool keep = !immediate_avl && rs1 == 0 && rd == 0;
  unsigned old_maximum = vector_vlmax(cpu.sr[CSR_VTYPE]);
  if (keep && (old_maximum != maximum || !old_maximum || cpu.sr[CSR_VL] > maximum))
    maximum = 0;
  if (!maximum)
  {
    cpu.sr[CSR_VTYPE] = (word_t)1 << (XLEN - 1);
    cpu.sr[CSR_VL] = 0;
  }
  else
  {
    word_t avl = immediate_avl ? rs1 : rs1 ? cpu.gpr[rs1] : rd ? ~(word_t)0 : cpu.sr[CSR_VL];
    cpu.sr[CSR_VTYPE] = requested;
    cpu.sr[CSR_VL] = avl < maximum ? avl : maximum;
  }
  cpu.sr[CSR_VSTART] = 0;
  vector_mark_dirty(false);
  cpu.csr_dirty = true;
  if (rd) cpu.gpr[rd] = cpu.sr[CSR_VL];
  return true;
}

static bool vector_group_valid(unsigned reg, unsigned group)
{
  return !(reg % group) && reg + group <= 32;
}

static uint64_t vector_element_read(unsigned reg, unsigned index, unsigned bytes)
{
  unsigned offset = index * bytes;
  const uint8_t *source = cpu.vreg[reg + offset / 16] + offset % 16;
  uint64_t value = 0;
  for (unsigned byte = 0; byte < bytes; byte++) value |= (uint64_t)source[byte] << (8 * byte);
  return value;
}

static uint64_t vector_snapshot_read(const uint8_t registers[32][16],
                                     unsigned reg, unsigned index, unsigned bytes)
{
  unsigned offset = index * bytes;
  const uint8_t *source = registers[reg + offset / 16] + offset % 16;
  uint64_t value = 0;
  for (unsigned byte = 0; byte < bytes; byte++) value |= (uint64_t)source[byte] << (8 * byte);
  return value;
}

static void vector_element_write(unsigned reg, unsigned index, unsigned bytes, uint64_t value)
{
  unsigned offset = index * bytes;
  uint8_t *destination = cpu.vreg[reg + offset / 16] + offset % 16;
  for (unsigned byte = 0; byte < bytes; byte++) destination[byte] = value >> (8 * byte);
}

static uint64_t vector_reverse_bits_in_bytes(uint64_t value)
{
  value = ((value & UINT64_C(0x5555555555555555)) << 1) |
          ((value & UINT64_C(0xaaaaaaaaaaaaaaaa)) >> 1);
  value = ((value & UINT64_C(0x3333333333333333)) << 2) |
          ((value & UINT64_C(0xcccccccccccccccc)) >> 2);
  return ((value & UINT64_C(0x0f0f0f0f0f0f0f0f)) << 4) |
         ((value & UINT64_C(0xf0f0f0f0f0f0f0f0)) >> 4);
}

static uint64_t vector_reverse_bytes(uint64_t value, unsigned bytes)
{
  uint64_t result = 0;
  for (unsigned byte = 0; byte < bytes; byte++)
    result |= ((value >> (8 * byte)) & 255) << (8 * (bytes - byte - 1));
  return result;
}

static uint64_t vector_fp_estimate(uint64_t operand, unsigned bytes, bool reciprocal_sqrt,
                                   unsigned rm, uint32_t *flags)
{
  unsigned fraction_bits = bytes == 4 ? 23 : 52;
  unsigned exponent_bits = bytes == 4 ? 8 : 11;
  unsigned bias = (1u << (exponent_bits - 1)) - 1;
  unsigned max_exponent = (1u << exponent_bits) - 1;
  uint64_t fraction_mask = (UINT64_C(1) << fraction_bits) - 1;
  uint64_t sign = (operand >> (fraction_bits + exponent_bits)) & 1;
  unsigned exponent = (operand >> fraction_bits) & max_exponent;
  uint64_t fraction = operand & fraction_mask;
  uint64_t canonical_nan = ((uint64_t)max_exponent << fraction_bits) |
      (UINT64_C(1) << (fraction_bits - 1));
  uint64_t infinity = (sign << (fraction_bits + exponent_bits)) |
      ((uint64_t)max_exponent << fraction_bits);
  *flags = 0;
  if (exponent == max_exponent && fraction)
  {
    if (!(fraction & (UINT64_C(1) << (fraction_bits - 1)))) *flags = 1u << 4;
    return canonical_nan;
  }
  if (!exponent && !fraction)
  {
    *flags = 1u << 3;
    return infinity;
  }
  if (reciprocal_sqrt && sign)
  {
    *flags = 1u << 4;
    return canonical_nan;
  }
  if (exponent == max_exponent) return sign << (fraction_bits + exponent_bits);
  int normalized_exponent = exponent;
  unsigned normalized_fraction = fraction >> (fraction_bits - 7);
  if (!exponent)
  {
    unsigned leading = 0;
    for (unsigned bit = 0; bit < fraction_bits; bit++)
      if (fraction & (UINT64_C(1) << bit)) leading = bit;
    normalized_exponent = (int)leading - (int)fraction_bits + 1;
    normalized_fraction = ((fraction << (fraction_bits - leading)) >>
                           (fraction_bits - 7)) & 127;
  }
  unsigned table_index = reciprocal_sqrt ?
      (((unsigned)normalized_exponent & 1) << 6) | (normalized_fraction >> 1) :
      normalized_fraction;
  unsigned estimate;
  if (reciprocal_sqrt)
  {
    unsigned denominator = 129 + 2 * (table_index & 63);
    unsigned numerator = table_index & 64 ? 8388608 : 4194304;
    unsigned low = 128;
    unsigned high = 256;
    while (low + 1 < high)
    {
      unsigned middle = (low + high) / 2;
      if (middle * middle * denominator <= numerator) low = middle;
      else high = middle;
    }
    estimate = low + ((2 * low + 1) * (2 * low + 1) * denominator <= 4 * numerator) - 128;
  }
  else
  {
    unsigned denominator = 257 + 2 * table_index;
    estimate = (131072 + denominator) / (2 * denominator) - 128;
  }
  int output_exponent = reciprocal_sqrt ?
      (3 * (int)bias - 1 - normalized_exponent) / 2 :
      2 * (int)bias - 1 - normalized_exponent;
  uint64_t significand = (UINT64_C(1) << fraction_bits) |
      ((uint64_t)estimate << (fraction_bits - 7));
  if (!reciprocal_sqrt && output_exponent <= 0)
  {
    significand >>= 1 - output_exponent;
    output_exponent = 0;
  }
  if (!reciprocal_sqrt && output_exponent >= (int)max_exponent)
  {
    *flags = 5;
    if (rm == 1 || (rm == 2 && !sign) || (rm == 3 && sign))
      return (sign << (fraction_bits + exponent_bits)) |
          ((uint64_t)(max_exponent - 1) << fraction_bits) | fraction_mask;
    return infinity;
  }
  return (sign << (fraction_bits + exponent_bits)) |
      ((uint64_t)output_exponent << fraction_bits) | (significand & fraction_mask);
}

static bool vector_mask_bit(unsigned reg, unsigned index)
{
  return (cpu.vreg[reg][index / 8] >> (index % 8)) & 1;
}

static uint64_t vector_integer_result(unsigned function, uint64_t left, uint64_t right,
                                      unsigned bits, bool carry_in)
{
  uint64_t mask = bits == 64 ? UINT64_MAX : (UINT64_C(1) << bits) - 1;
  uint64_t sign = UINT64_C(1) << (bits - 1);
  left &= mask;
  right &= mask;
  switch (function)
  {
  case 0x00: return left + right;
  case 0x02: return left - right;
  case 0x03: return right - left;
  case 0x04: return left < right ? left : right;
  case 0x05: return (left ^ sign) < (right ^ sign) ? left : right;
  case 0x06: return left > right ? left : right;
  case 0x07: return (left ^ sign) > (right ^ sign) ? left : right;
  case 0x09: return left & right;
  case 0x0a: return left | right;
  case 0x0b: return left ^ right;
  case 0x10: return left + right + carry_in;
  case 0x11: return ((__uint128_t)left + right + carry_in) >> bits;
  case 0x12: return left - right - carry_in;
  case 0x13: return (__uint128_t)left < (__uint128_t)right + carry_in;
  case 0x25: return left << (right & (bits - 1));
  case 0x28: return left >> (right & (bits - 1));
  case 0x29: return (uint64_t)((int64_t)((left ^ sign) - sign) >> (right & (bits - 1)));
  case 0x18: return left == right;
  case 0x19: return left != right;
  case 0x1a: return left < right;
  case 0x1b: return (left ^ sign) < (right ^ sign);
  case 0x1c: return left <= right;
  case 0x1d: return (left ^ sign) <= (right ^ sign);
  case 0x1e: return left > right;
  case 0x1f: return (left ^ sign) > (right ^ sign);
  default: return 0;
  }
}

static bool vector_mask_logic_result(unsigned function, bool left, bool right)
{
  switch (function & 7)
  {
  case 0: return left && !right;
  case 1: return left && right;
  case 2: return left || right;
  case 3: return left != right;
  case 4: return left || !right;
  case 5: return !(left && right);
  case 6: return !(left || right);
  default: return left == right;
  }
}

static __int128 vector_signed_value(uint64_t value, unsigned bits)
{
  if (bits < 64) value &= (UINT64_C(1) << bits) - 1;
  __int128 result = value;
  if (value & (UINT64_C(1) << (bits - 1))) result -= (__int128)1 << bits;
  return result;
}

static uint64_t vector_saturating_result(unsigned function, uint64_t left,
                                         uint64_t right, unsigned bits,
                                         bool *saturated)
{
  uint64_t mask = bits == 64 ? UINT64_MAX : (UINT64_C(1) << bits) - 1;
  left &= mask;
  right &= mask;
  bool signed_operation = function & 1;
  __int128 left_value = signed_operation ? vector_signed_value(left, bits) : left;
  __int128 right_value = signed_operation ? vector_signed_value(right, bits) : right;
  __int128 result = function & 2 ? left_value - right_value : left_value + right_value;
  __int128 minimum = signed_operation ? -((__int128)1 << (bits - 1)) : 0;
  __int128 maximum = signed_operation ? ((__int128)1 << (bits - 1)) - 1 : mask;
  if (result < minimum)
  {
    result = minimum;
    *saturated = true;
  }
  if (result > maximum)
  {
    result = maximum;
    *saturated = true;
  }
  return (uint64_t)result & mask;
}

static __int128 vector_round_result(__int128 value, unsigned shift, unsigned mode)
{
  __int128 scale = (__int128)1 << shift;
  __int128 quotient = value / scale;
  __int128 remainder = value % scale;
  if (remainder < 0)
  {
    quotient--;
    remainder += scale;
  }
  bool odd = (quotient & 1) != 0;
  if ((mode == 0 && 2 * remainder >= scale) ||
      (mode == 1 && (2 * remainder > scale || (2 * remainder == scale && odd))) ||
      (mode == 3 && remainder && !odd))
    quotient++;
  return quotient;
}

static uint64_t vector_rounded_fixed_result(unsigned function, uint64_t left,
                                             uint64_t right, unsigned bits,
                                             unsigned mode, bool *saturated)
{
  uint64_t mask = bits == 64 ? UINT64_MAX : (UINT64_C(1) << bits) - 1;
  left &= mask;
  right &= mask;
  bool signed_operation = function & 1;
  __int128 left_value = signed_operation ? vector_signed_value(left, bits) : left;
  __int128 right_value = signed_operation ? vector_signed_value(right, bits) : right;
  __int128 value;
  unsigned shift;
  if (function <= 0x0b)
  {
    value = function & 2 ? left_value - right_value : left_value + right_value;
    shift = 1;
  }
  else if (function == 0x27)
  {
    value = vector_signed_value(left, bits) * vector_signed_value(right, bits);
    shift = bits - 1;
  }
  else
  {
    value = left_value;
    shift = right & (bits - 1);
  }
  value = vector_round_result(value, shift, mode);
  if (function == 0x27)
  {
    __int128 minimum = -((__int128)1 << (bits - 1));
    __int128 maximum = ((__int128)1 << (bits - 1)) - 1;
    if (value < minimum)
    {
      value = minimum;
      *saturated = true;
    }
    if (value > maximum)
    {
      value = maximum;
      *saturated = true;
    }
  }
  return (uint64_t)value & mask;
}

static uint64_t vector_clip_result(bool signed_operation, uint64_t source,
                                   uint64_t shift_operand, unsigned bits,
                                   unsigned mode, bool *saturated)
{
  unsigned source_bits = bits * 2;
  unsigned shift = shift_operand & (source_bits - 1);
  __int128 value = signed_operation ? vector_signed_value(source, source_bits) : source;
  value = vector_round_result(value, shift, mode);
  __int128 minimum = signed_operation ? -((__int128)1 << (bits - 1)) : 0;
  __int128 maximum = signed_operation ? ((__int128)1 << (bits - 1)) - 1 :
      ((__int128)1 << bits) - 1;
  if (value < minimum)
  {
    value = minimum;
    *saturated = true;
  }
  if (value > maximum)
  {
    value = maximum;
    *saturated = true;
  }
  return (uint64_t)value & (bits == 64 ? UINT64_MAX : (UINT64_C(1) << bits) - 1);
}

static uint64_t vector_muldiv_result(unsigned function, uint64_t left, uint64_t right,
                                     unsigned bits)
{
  uint64_t mask = bits == 64 ? UINT64_MAX : (UINT64_C(1) << bits) - 1;
  left &= mask;
  right &= mask;
  unsigned operation = function & 7;
  if (operation < 4)
  {
    if (!right) return operation & 2 ? left : mask;
    if (operation & 1)
    {
      __int128 dividend = vector_signed_value(left, bits);
      __int128 divisor = vector_signed_value(right, bits);
      return (uint64_t)(operation & 2 ? dividend % divisor : dividend / divisor) & mask;
    }
    return operation & 2 ? left % right : left / right;
  }
  if (operation == 5) return left * right & mask;
  __uint128_t product = operation == 4 ? (__uint128_t)left * right :
      (__uint128_t)(vector_signed_value(left, bits) *
                    (operation == 6 ? (__int128)right : vector_signed_value(right, bits)));
  return (uint64_t)(product >> bits) & mask;
}

bool riscv_vector_execute(uint32_t instruction)
{
  if (!riscv_vector_context_enabled() ||
      ((instruction >> 12) & 7) == 7) return false;
  word_t vtype = cpu.sr[CSR_VTYPE];
  unsigned maximum = vector_vlmax(vtype);
  unsigned destination = (instruction >> 7) & 31;
  unsigned source1 = (instruction >> 15) & 31;
  unsigned source2 = (instruction >> 20) & 31;
  unsigned form = (instruction >> 12) & 7;
  unsigned function = instruction >> 26;
  bool unmasked = (instruction & (1u << 25)) != 0;
  unsigned bytes = 1u << ((vtype >> 3) & 7);
  if (function == 0x27 && form == 3)
  {
    unsigned move_group = source1 + 1;
    if (!unmasked || !maximum ||
        (move_group != 1 && move_group != 2 && move_group != 4 && move_group != 8) ||
        cpu.sr[CSR_VSTART] >= move_group * 16 / bytes ||
        !vector_group_valid(destination, move_group) ||
        !vector_group_valid(source2, move_group)) return false;
    for (unsigned offset = cpu.sr[CSR_VSTART] * bytes; offset < move_group * 16;
         offset += bytes)
      memmove(cpu.vreg[destination + offset / 16] + offset % 16,
              cpu.vreg[source2 + offset / 16] + offset % 16, bytes);
    cpu.sr[CSR_VSTART] = 0;
    vector_mark_dirty(false);
    cpu.csr_dirty = true;
    return true;
  }
  if (!maximum || cpu.sr[CSR_VL] > maximum) return false;
  unsigned group = (vtype & 7) < 4 ? 1u << (vtype & 7) : 1;
  if (function == 0x10 && form == 6)
  {
    if (!unmasked || source2 != 0) return false;
    if (cpu.sr[CSR_VSTART] < cpu.sr[CSR_VL])
      vector_element_write(destination, 0, bytes,
                           (uint64_t)(int64_t)(sword_t)cpu.gpr[source1]);
    cpu.sr[CSR_VSTART] = 0;
    vector_mark_dirty(false);
    cpu.csr_dirty = true;
    return true;
  }
  bool zvbb_unary = function == 0x12 && form == 2 &&
      (source1 == 8 || source1 == 9 || source1 == 10 ||
       source1 == 12 || source1 == 13 || source1 == 14);
  bool zvbb_binary = (function == 0x01 && (form == 0 || form == 4)) ||
      ((function == 0x14 || function == 0x15) &&
       (form == 0 || form == 4 || form == 3)) ||
      (function == 0x35 && (form == 0 || form == 3 || form == 4));
  if (zvbb_unary || zvbb_binary)
  {
    bool widening = function == 0x35;
    int encoded_lmul = vtype & 7;
    int lmul = encoded_lmul < 4 ? encoded_lmul : encoded_lmul - 8;
    int destination_exponent = lmul + (int)widening;
    unsigned destination_group = destination_exponent > 0 ? 1u << destination_exponent : 1;
    bool source2_overlap = destination < source2 + group &&
        source2 < destination + destination_group;
    bool source1_overlap = destination < source1 + group &&
        source1 < destination + destination_group;
    if (!riscv_zvbb_enabled() ||
        (widening && (bytes == 8 || destination_exponent > 3)) ||
        !vector_group_valid(destination, destination_group) ||
        !vector_group_valid(source2, group) ||
        (form == 0 && !vector_group_valid(source1, group)) ||
        (!unmasked && !destination) ||
        (widening && source2_overlap &&
         (lmul < 0 || destination + destination_group != source2 + group)) ||
        (widening && form == 0 && source1_overlap &&
         (lmul < 0 || destination + destination_group != source1 + group)))
      return false;
    uint8_t registers[32][16];
    memcpy(registers, cpu.vreg, sizeof(registers));
    unsigned bits = bytes * 8;
    uint64_t mask = bytes == 8 ? UINT64_MAX : (UINT64_C(1) << bits) - 1;
    uint64_t scalar = (uint64_t)(int64_t)(sword_t)cpu.gpr[source1];
    for (unsigned index = cpu.sr[CSR_VSTART]; index < cpu.sr[CSR_VL]; index++)
    {
      if (!unmasked && !vector_mask_bit(0, index)) continue;
      uint64_t value = vector_snapshot_read(registers, source2, index, bytes);
      uint64_t operand = form == 0 ?
          vector_snapshot_read(registers, source1, index, bytes) :
          form == 4 ? scalar : source1 | ((uint64_t)(!widening && (function & 1)) << 5);
      uint64_t result;
      if (zvbb_unary)
      {
        if (source1 == 8 || source1 == 10) value = vector_reverse_bits_in_bytes(value);
        if (source1 == 9 || source1 == 10) value = vector_reverse_bytes(value, bytes);
        if (source1 == 12) result = value ? __builtin_clzll(value) - (64 - bits) : bits;
        else if (source1 == 13) result = value ? __builtin_ctzll(value) : bits;
        else if (source1 == 14) result = __builtin_popcountll(value);
        else result = value;
      }
      else if (function == 0x01) result = value & ~operand;
      else if (widening)
      {
        result = value << (operand & (2 * bits - 1));
        vector_element_write(destination, index, bytes * 2, result);
        continue;
      }
      else
      {
        unsigned shift = operand & (bits - 1);
        if (!shift) result = value;
        else if (function == 0x15 && form != 3)
          result = (value << shift) | (value >> (bits - shift));
        else result = (value >> shift) | (value << (bits - shift));
      }
      vector_element_write(destination, index, bytes, result & mask);
    }
    cpu.sr[CSR_VSTART] = 0;
    vector_mark_dirty(false);
    cpu.csr_dirty = true;
    return true;
  }
  bool fp_extract = function == 0x10 && form == 1 && unmasked && source1 == 0;
  bool fp_insert = function == 0x10 && form == 5 && unmasked && source2 == 0;
  bool fp_broadcast = function == 0x17 && form == 5 && unmasked && source2 == 0;
  bool fp_merge = function == 0x17 && form == 5 && !unmasked;
  bool fp_slide = (function == 0x0e || function == 0x0f) && form == 5;
  bool fp_arithmetic = (form == 1 || form == 5) &&
      (function == 0x00 || function == 0x02 || function == 0x04 ||
       function == 0x06 || (function >= 0x08 && function <= 0x0a) ||
       function == 0x20 || function == 0x24 ||
       (function >= 0x28 && function <= 0x2f) ||
       (form == 5 && (function == 0x21 || function == 0x27)));
  bool fp_unary = function == 0x13 && form == 1 &&
      (source1 == 0 || source1 == 16);
  bool fp_estimate = function == 0x13 && form == 1 &&
      (source1 == 4 || source1 == 5);
  bool fp_convert = function == 0x12 && form == 1 &&
      (source1 <= 3 || source1 == 6 || source1 == 7);
  bool fp_compare = (form == 1 || form == 5) &&
      (function == 0x18 || function == 0x19 || function == 0x1b ||
       function == 0x1c ||
       (form == 5 && (function == 0x1d || function == 0x1f)));
  if (fp_extract || fp_insert || fp_broadcast || fp_merge || fp_slide ||
      fp_arithmetic || fp_unary || fp_estimate || fp_convert || fp_compare)
  {
    word_t required = CSR_MISA_EXT_F | (bytes == 8 ? CSR_MISA_EXT_D : 0);
    if ((bytes != 4 && bytes != 8) ||
        (cpu.sr[CSR_MISA] & required) != required ||
        !vector_fp_context_enabled() ||
        ((cpu.sr[CSR_FCSR] >> 5) & 7) > 4) return false;
    if (!fp_extract && !fp_insert &&
        (!vector_group_valid(destination, fp_compare ? 1 : group) ||
         ((fp_merge || fp_slide || fp_arithmetic || fp_unary || fp_estimate || fp_convert ||
           fp_compare) &&
          !vector_group_valid(source2, group)) ||
         ((fp_arithmetic || fp_compare) && form == 1 &&
          !vector_group_valid(source1, group)) ||
         (!unmasked && !fp_compare && destination == 0) ||
         (fp_compare && destination >= source2 && destination < source2 + group &&
          destination != source2) ||
         (fp_compare && form == 1 && destination >= source1 &&
          destination < source1 + group && destination != source1) ||
         (fp_slide && function == 0x0e && destination < source2 + group &&
          source2 < destination + group))) return false;
    uint32_t fp_flags = 0;
    if (fp_extract)
    {
      uint64_t value = vector_element_read(source2, 0, bytes);
      cpu.fpr[destination] = bytes == 4 ? riscv_fp_box_s((uint32_t)value) : value;
    }
    else
    {
      uint64_t scalar = form == 5 ? cpu.fpr[source1] : 0;
      if (bytes == 4 && form == 5) scalar = riscv_fp_read_s(scalar);
      if (fp_insert)
      {
        if (cpu.sr[CSR_VSTART] < cpu.sr[CSR_VL])
          vector_element_write(destination, 0, bytes, scalar);
      }
      else
      {
        for (unsigned index = cpu.sr[CSR_VSTART]; index < cpu.sr[CSR_VL]; index++)
        {
          bool active = unmasked || vector_mask_bit(0, index);
          if (fp_arithmetic || fp_unary || fp_estimate || fp_convert || fp_compare)
          {
            if (!active) continue;
            uint64_t left = vector_element_read(source2, index, bytes);
            uint64_t right = form == 1 ?
                vector_element_read(source1, index, bytes) : scalar;
            if (function == 0x21 || function == 0x27 ||
                function == 0x1d || function == 0x1f)
            {
              uint64_t temporary = left;
              left = right;
              right = temporary;
            }
            unsigned rm = (cpu.sr[CSR_FCSR] >> 5) & 7;
            uint32_t flags = 0;
            uint64_t result;
            if (fp_estimate)
              result = vector_fp_estimate(left, bytes, source1 == 4, rm, &flags);
            else if (fp_convert)
            {
              bool unsigned_integer = !(source1 & 1);
              if (source1 == 2 || source1 == 3)
                result = bytes == 4 ?
                    riscv_int_to_fp_s(left, rm, unsigned_integer, false, &flags) :
                    riscv_int_to_fp_d(left, rm, unsigned_integer, true, &flags);
              else
                result = bytes == 4 ?
                    riscv_fp_to_int_s(left, source1 >= 6 ? 1 : rm,
                                      unsigned_integer, false, &flags) :
                    riscv_fp_to_int_d(left, source1 >= 6 ? 1 : rm,
                                      unsigned_integer, true, &flags);
            }
            else if (fp_unary)
            {
              result = source1 == 16 ?
                  (bytes == 4 ? riscv_fp_class_s(left) : riscv_fp_class_d(left)) :
                  (bytes == 4 ? riscv_fp_sqrt_s(left, rm, &flags) :
                                riscv_fp_sqrt_d(left, rm, &flags));
            }
            else if (function >= 0x28 && function <= 0x2f)
            {
              uint64_t old = vector_element_read(destination, index, bytes);
              uint64_t factor = function & 4 ? left : old;
              uint64_t addend = function & 4 ? old : left;
              bool negate_product = (function & 1) != 0;
              bool negate_addend = ((function & 1) ^ ((function >> 1) & 1)) != 0;
              result = bytes == 4 ?
                  riscv_fp_fma_s(right, factor, addend, rm, negate_product,
                                 negate_addend, &flags) :
                  riscv_fp_fma_d(right, factor, addend, rm, negate_product,
                                 negate_addend, &flags);
            }
            else if (fp_compare)
            {
              if (bytes == 4)
              {
                if (function == 0x18 || function == 0x1c)
                  result = riscv_fp_eq_s(left, right, &flags);
                else if (function == 0x19 || function == 0x1f)
                  result = riscv_fp_le_s(left, right, &flags);
                else result = riscv_fp_lt_s(left, right, &flags);
              }
              else
              {
                if (function == 0x18 || function == 0x1c)
                  result = riscv_fp_eq_d(left, right, &flags);
                else if (function == 0x19 || function == 0x1f)
                  result = riscv_fp_le_d(left, right, &flags);
                else result = riscv_fp_lt_d(left, right, &flags);
              }
              if (function == 0x1c) result = !result;
            }
            else if (function >= 0x08 && function <= 0x0a)
            {
              uint64_t sign = bytes == 4 ? UINT64_C(1) << 31 : UINT64_C(1) << 63;
              uint64_t source_sign = function == 0x08 ? right & sign :
                  function == 0x09 ? (~right) & sign : (left ^ right) & sign;
              result = (left & ~sign) | source_sign;
            }
            else if (bytes == 4)
            {
              if (function == 0x00) result = riscv_fp_add_s(left, right, rm, &flags);
              else if (function == 0x02 || function == 0x27)
                result = riscv_fp_sub_s(left, right, rm, &flags);
              else if (function == 0x04) result = riscv_fp_min_s(left, right, &flags);
              else if (function == 0x06) result = riscv_fp_max_s(left, right, &flags);
              else if (function == 0x24) result = riscv_fp_mul_s(left, right, rm, &flags);
              else result = riscv_fp_div_s(left, right, rm, &flags);
            }
            else
            {
              if (function == 0x00) result = riscv_fp_add_d(left, right, rm, &flags);
              else if (function == 0x02 || function == 0x27)
                result = riscv_fp_sub_d(left, right, rm, &flags);
              else if (function == 0x04) result = riscv_fp_min_d(left, right, &flags);
              else if (function == 0x06) result = riscv_fp_max_d(left, right, &flags);
              else if (function == 0x24) result = riscv_fp_mul_d(left, right, rm, &flags);
              else result = riscv_fp_div_d(left, right, rm, &flags);
            }
            if (fp_compare)
            {
              uint8_t *mask_byte = &cpu.vreg[destination][index / 8];
              uint8_t bit = 1u << (index % 8);
              *mask_byte = (*mask_byte & ~bit) | (result ? bit : 0);
            }
            else vector_element_write(destination, index, bytes, result);
            fp_flags |= flags;
          }
          else if (fp_slide)
          {
            if (!active) continue;
            bool upward = function == 0x0e;
            if ((upward && index == 0) || (!upward && index + 1 == cpu.sr[CSR_VL]))
              vector_element_write(destination, index, bytes, scalar);
            else if (upward)
              vector_element_write(destination, index, bytes,
                                   vector_element_read(source2, index - 1, bytes));
            else
              vector_element_write(destination, index, bytes,
                                   index + 1 < maximum ?
                                   vector_element_read(source2, index + 1, bytes) : 0);
          }
          else
          {
            uint64_t value = fp_merge && !active ?
                vector_element_read(source2, index, bytes) : scalar;
            vector_element_write(destination, index, bytes, value);
          }
        }
      }
    }
    cpu.sr[CSR_FCSR] |= fp_flags;
    cpu.sr[CSR_VSTART] = 0;
    vector_mark_dirty(true);
    cpu.csr_dirty = true;
    return true;
  }
  if (function == 0x12 && form == 1 &&
      (source1 == 12 || source1 == 20 || source1 == 21))
  {
    bool widen = source1 == 12;
    int encoded_lmul = vtype & 7;
    int lmul = encoded_lmul < 4 ? encoded_lmul : encoded_lmul - 8;
    int source_exponent = lmul + (widen ? 0 : 1);
    int destination_exponent = lmul + (widen ? 1 : 0);
    unsigned source_group = source_exponent > 0 ? 1u << source_exponent : 1;
    unsigned destination_group = destination_exponent > 0 ? 1u << destination_exponent : 1;
    bool overlap = destination < source2 + source_group &&
        source2 < destination + destination_group;
    word_t required = CSR_MISA_EXT_F | (bytes == 4 ? CSR_MISA_EXT_D : 0);
    if ((bytes != 4 && (bytes != 2 || !riscv_zvfhmin_enabled() || source1 == 21)) ||
        source_exponent > 3 || destination_exponent > 3 ||
        (cpu.sr[CSR_MISA] & required) != required ||
        !vector_fp_context_enabled() ||
        ((cpu.sr[CSR_FCSR] >> 5) & 7) > 4 ||
        !vector_group_valid(destination, destination_group) ||
        !vector_group_valid(source2, source_group) ||
        (!unmasked && !destination) ||
        (overlap && (widen ?
         (source_exponent < 0 || destination + destination_group != source2 + source_group) :
         destination != source2))) return false;
    uint8_t registers[32][16];
    memcpy(registers, cpu.vreg, sizeof(registers));
    uint32_t fp_flags = 0;
    for (unsigned index = cpu.sr[CSR_VSTART]; index < cpu.sr[CSR_VL]; index++)
    {
      if (!unmasked && !vector_mask_bit(0, index)) continue;
      uint64_t operand = vector_snapshot_read(registers, source2, index,
                                               widen ? bytes : bytes * 2);
      uint32_t flags = 0;
      uint64_t result;
      if (bytes == 2)
        result = widen ? riscv_fp_convert_h_to_s(operand, &flags) :
            riscv_fp_convert_s_to_h(operand, (cpu.sr[CSR_FCSR] >> 5) & 7, &flags);
      else
        result = widen ? riscv_fp_convert_s_to_d(operand, 0, &flags) :
            riscv_fp_convert_d_to_s(operand,
                                    source1 == 21 ? 1 : (cpu.sr[CSR_FCSR] >> 5) & 7,
                                    &flags);
      if (source1 == 21 && (flags & 1)) result |= 1;
      vector_element_write(destination, index, widen ? bytes * 2 : bytes, result);
      fp_flags |= flags;
    }
    cpu.sr[CSR_FCSR] |= fp_flags;
    cpu.sr[CSR_VSTART] = 0;
    vector_mark_dirty(true);
    cpu.csr_dirty = true;
    return true;
  }
  bool fp_integer_widen = function == 0x12 && form == 1 &&
      ((source1 >= 8 && source1 <= 11) || source1 == 14 || source1 == 15);
  bool fp_integer_narrow = function == 0x12 && form == 1 &&
      ((source1 >= 16 && source1 <= 19) || source1 == 22 || source1 == 23);
  if (fp_integer_widen || fp_integer_narrow)
  {
    bool to_float = source1 == 10 || source1 == 11 ||
        source1 == 18 || source1 == 19;
    bool unsigned_integer = !(source1 & 1);
    unsigned source_bytes = bytes * (fp_integer_narrow ? 2 : 1);
    unsigned destination_bytes = bytes * (fp_integer_widen ? 2 : 1);
    unsigned fp_bytes = to_float ? destination_bytes : source_bytes;
    unsigned integer_bytes = to_float ? source_bytes : destination_bytes;
    int encoded_lmul = vtype & 7;
    int lmul = encoded_lmul < 4 ? encoded_lmul : encoded_lmul - 8;
    int source_exponent = lmul + (int)fp_integer_narrow;
    int destination_exponent = lmul + (int)fp_integer_widen;
    unsigned source_group = source_exponent > 0 ? 1u << source_exponent : 1;
    unsigned destination_group = destination_exponent > 0 ? 1u << destination_exponent : 1;
    bool overlap = destination < source2 + source_group &&
        source2 < destination + destination_group;
    word_t required = CSR_MISA_EXT_F | (fp_bytes == 8 ? CSR_MISA_EXT_D : 0);
    if ((fp_bytes != 4 && fp_bytes != 8) ||
        (integer_bytes != 2 && integer_bytes != 4 && integer_bytes != 8) ||
        source_bytes > 8 || destination_bytes > 8 ||
        source_exponent > 3 || destination_exponent > 3 ||
        (cpu.sr[CSR_MISA] & required) != required ||
        !vector_fp_context_enabled() ||
        ((cpu.sr[CSR_FCSR] >> 5) & 7) > 4 ||
        !vector_group_valid(destination, destination_group) ||
        !vector_group_valid(source2, source_group) ||
        (!unmasked && !destination) ||
        (overlap && (fp_integer_widen ?
         (lmul < 0 || destination + destination_group != source2 + source_group) :
         destination != source2))) return false;
    uint8_t registers[32][16];
    memcpy(registers, cpu.vreg, sizeof(registers));
    uint32_t fp_flags = 0;
    unsigned rm = source1 & 4 ? 1 : (cpu.sr[CSR_FCSR] >> 5) & 7;
    for (unsigned index = cpu.sr[CSR_VSTART]; index < cpu.sr[CSR_VL]; index++)
    {
      if (!unmasked && !vector_mask_bit(0, index)) continue;
      uint64_t operand = vector_snapshot_read(registers, source2, index, source_bytes);
      uint32_t flags = 0;
      uint64_t result;
      if (to_float)
      {
        if (integer_bytes == 2 && !unsigned_integer)
          operand = (uint64_t)(int64_t)(int16_t)operand;
        result = fp_bytes == 4 ?
            riscv_int_to_fp_s(operand, rm, unsigned_integer, integer_bytes == 8, &flags) :
            riscv_int_to_fp_d(operand, rm, unsigned_integer, integer_bytes == 8, &flags);
      }
      else
      {
        result = fp_bytes == 4 ?
            riscv_fp_to_int_s(operand, rm, unsigned_integer, integer_bytes == 8, &flags) :
            riscv_fp_to_int_d(operand, rm, unsigned_integer, integer_bytes == 8, &flags);
        if (integer_bytes == 2)
        {
          int64_t signed_result = (int32_t)result;
          if (unsigned_integer && result > UINT16_MAX)
          {
            result = UINT16_MAX;
            flags = 1u << 4;
          }
          else if (!unsigned_integer && signed_result > INT16_MAX)
          {
            result = INT16_MAX;
            flags = 1u << 4;
          }
          else if (!unsigned_integer && signed_result < INT16_MIN)
          {
            result = (uint16_t)INT16_MIN;
            flags = 1u << 4;
          }
        }
      }
      vector_element_write(destination, index, destination_bytes, result);
      fp_flags |= flags;
    }
    cpu.sr[CSR_FCSR] |= fp_flags;
    cpu.sr[CSR_VSTART] = 0;
    vector_mark_dirty(true);
    cpu.csr_dirty = true;
    return true;
  }
  if ((form == 1 || form == 5) &&
      (function == 0x30 || function == 0x32 || function == 0x34 ||
       function == 0x36 || function == 0x38 ||
       (function >= 0x3c && function <= 0x3f)))
  {
    bool wide_source = function == 0x34 || function == 0x36;
    bool fused = function >= 0x3c;
    int encoded_lmul = vtype & 7;
    int lmul = encoded_lmul < 4 ? encoded_lmul : encoded_lmul - 8;
    int destination_exponent = lmul + 1;
    int source_exponent = lmul + (int)wide_source;
    unsigned destination_group = destination_exponent > 0 ? 1u << destination_exponent : 1;
    unsigned source_group = source_exponent > 0 ? 1u << source_exponent : 1;
    bool source2_overlap = destination < source2 + source_group &&
        source2 < destination + destination_group;
    bool source1_overlap = destination < source1 + group &&
        source1 < destination + destination_group;
    word_t required = CSR_MISA_EXT_F | CSR_MISA_EXT_D;
    if (bytes != 4 || destination_exponent > 3 || source_exponent > 3 ||
        (cpu.sr[CSR_MISA] & required) != required ||
        !vector_fp_context_enabled() ||
        ((cpu.sr[CSR_FCSR] >> 5) & 7) > 4 ||
        !vector_group_valid(destination, destination_group) ||
        !vector_group_valid(source2, source_group) ||
        (form == 1 && !vector_group_valid(source1, group)) ||
        (wide_source && form == 1 && source2 < source1 + group &&
         source1 < source2 + source_group) ||
        (!unmasked && !destination) ||
        (source2_overlap && !wide_source &&
         (lmul < 0 || destination + destination_group != source2 + source_group)) ||
        (form == 1 && source1_overlap &&
         (lmul < 0 || destination + destination_group != source1 + group))) return false;
    uint8_t registers[32][16];
    memcpy(registers, cpu.vreg, sizeof(registers));
    uint64_t scalar = form == 5 ? riscv_fp_read_s(cpu.fpr[source1]) : 0;
    uint32_t fp_flags = 0;
    for (unsigned index = cpu.sr[CSR_VSTART]; index < cpu.sr[CSR_VL]; index++)
    {
      if (!unmasked && !vector_mask_bit(0, index)) continue;
      uint32_t flags = 0;
      uint32_t operand_flags = 0;
      uint64_t left = vector_snapshot_read(registers, source2, index, wide_source ? 8 : 4);
      uint64_t right = form == 1 ?
          vector_snapshot_read(registers, source1, index, 4) : scalar;
      if (!wide_source)
      {
        left = riscv_fp_convert_s_to_d(left, 0, &operand_flags);
        fp_flags |= operand_flags;
      }
      right = riscv_fp_convert_s_to_d(right, 0, &operand_flags);
      fp_flags |= operand_flags;
      unsigned rm = (cpu.sr[CSR_FCSR] >> 5) & 7;
      uint64_t result;
      if (fused)
      {
        uint64_t old = vector_snapshot_read(registers, destination, index, 8);
        bool negate_product = (function & 1) != 0;
        bool negate_addend = ((function & 1) ^ ((function >> 1) & 1)) != 0;
        result = riscv_fp_fma_d(right, left, old, rm, negate_product,
                                negate_addend, &flags);
      }
      else if (function == 0x38)
        result = riscv_fp_mul_d(left, right, rm, &flags);
      else if (function == 0x30 || function == 0x34)
        result = riscv_fp_add_d(left, right, rm, &flags);
      else result = riscv_fp_sub_d(left, right, rm, &flags);
      vector_element_write(destination, index, 8, result);
      fp_flags |= flags;
    }
    cpu.sr[CSR_FCSR] |= fp_flags;
    cpu.sr[CSR_VSTART] = 0;
    vector_mark_dirty(true);
    cpu.csr_dirty = true;
    return true;
  }
  if (form == 1 && (function == 0x01 || function == 0x03 ||
                    function == 0x05 || function == 0x07 ||
                    function == 0x31 || function == 0x33))
  {
    bool widen = function == 0x31 || function == 0x33;
    unsigned result_bytes = widen ? 8 : bytes;
    word_t required = CSR_MISA_EXT_F | (result_bytes == 8 ? CSR_MISA_EXT_D : 0);
    if ((bytes != 4 && bytes != 8) || (widen && bytes != 4) ||
        (cpu.sr[CSR_MISA] & required) != required ||
        !vector_fp_context_enabled() ||
        ((cpu.sr[CSR_FCSR] >> 5) & 7) > 4 ||
        !vector_group_valid(source2, group) ||
        (widen && source1 >= source2 && source1 < source2 + group) ||
        cpu.sr[CSR_VSTART]) return false;
    if (cpu.sr[CSR_VL])
    {
      uint8_t registers[32][16];
      memcpy(registers, cpu.vreg, sizeof(registers));
      uint64_t result = vector_snapshot_read(registers, source1, 0, result_bytes);
      uint32_t fp_flags = 0;
      unsigned rm = (cpu.sr[CSR_FCSR] >> 5) & 7;
      for (unsigned index = 0; index < cpu.sr[CSR_VL]; index++)
      {
        if (!unmasked && !vector_mask_bit(0, index)) continue;
        uint64_t element = vector_snapshot_read(registers, source2, index, bytes);
        uint32_t flags = 0;
        if (widen)
        {
          element = riscv_fp_convert_s_to_d(element, 0, &flags);
          fp_flags |= flags;
        }
        if (function == 0x05)
          result = bytes == 4 ? riscv_fp_min_s(result, element, &flags) :
                                riscv_fp_min_d(result, element, &flags);
        else if (function == 0x07)
          result = bytes == 4 ? riscv_fp_max_s(result, element, &flags) :
                                riscv_fp_max_d(result, element, &flags);
        else result = result_bytes == 4 ?
            riscv_fp_add_s(result, element, rm, &flags) :
            riscv_fp_add_d(result, element, rm, &flags);
        fp_flags |= flags;
      }
      vector_element_write(destination, 0, result_bytes, result);
      cpu.sr[CSR_FCSR] |= fp_flags;
    }
    cpu.sr[CSR_VSTART] = 0;
    vector_mark_dirty(true);
    cpu.csr_dirty = true;
    return true;
  }
  bool mask_scan = function == 0x10 && form == 2 &&
      (source1 == 16 || source1 == 17);
  if (mask_scan)
  {
    if (cpu.sr[CSR_VSTART]) return false;
    word_t result = source1 == 17 ? ~(word_t)0 : 0;
    for (unsigned index = 0; index < cpu.sr[CSR_VL]; index++)
    {
      if (!vector_mask_bit(source2, index) ||
          (!unmasked && !vector_mask_bit(0, index))) continue;
      if (source1 == 17)
      {
        result = index;
        break;
      }
      result++;
    }
    if (destination) cpu.gpr[destination] = result;
    cpu.sr[CSR_VSTART] = 0;
    vector_mark_dirty(false);
    cpu.csr_dirty = true;
    return true;
  }
  bool slide = (function == 0x0e || function == 0x0f) &&
      (form == 3 || form == 4 || form == 6);
  if (slide)
  {
    bool upward = function == 0x0e;
    bool single = form == 6;
    if (!vector_group_valid(destination, group) ||
        !vector_group_valid(source2, group) ||
        (!unmasked && destination == 0) ||
        (upward && destination < source2 + group &&
         source2 < destination + group)) return false;
    word_t offset = single ? 1 : form == 3 ? source1 : cpu.gpr[source1];
    uint64_t scalar = (uint64_t)(int64_t)(sword_t)cpu.gpr[source1];
    for (unsigned index = cpu.sr[CSR_VSTART]; index < cpu.sr[CSR_VL]; index++)
    {
      if (!unmasked && !vector_mask_bit(0, index)) continue;
      if (single && ((upward && index == 0) ||
                     (!upward && index + 1 == cpu.sr[CSR_VL])))
        vector_element_write(destination, index, bytes, scalar);
      else if (upward)
      {
        if (offset <= index)
          vector_element_write(destination, index, bytes,
                               vector_element_read(source2, index - offset, bytes));
      }
      else
        vector_element_write(destination, index, bytes,
                             offset < maximum - index ?
                             vector_element_read(source2, index + offset, bytes) : 0);
    }
    cpu.sr[CSR_VSTART] = 0;
    vector_mark_dirty(false);
    cpu.csr_dirty = true;
    return true;
  }
  bool gather16 = function == 0x0e && form == 0;
  bool gather = (function == 0x0c && (form == 0 || form == 3 || form == 4)) ||
      gather16;
  if (gather)
  {
    unsigned index_bytes = gather16 ? 2 : bytes;
    unsigned index_group = group;
    if (gather16)
    {
      unsigned encoded_lmul = vtype & 7;
      int lmul = encoded_lmul < 4 ? (int)encoded_lmul : (int)encoded_lmul - 8;
      int index_lmul = lmul + 1 - (int)((vtype >> 3) & 7);
      if (index_lmul < -3 || index_lmul > 3) return false;
      index_group = index_lmul > 0 ? 1u << index_lmul : 1;
    }
    if (!vector_group_valid(destination, group) ||
        !vector_group_valid(source2, group) ||
        (form == 0 && !vector_group_valid(source1, index_group)) ||
        (!unmasked && destination == 0) ||
        (destination < source2 + group && source2 < destination + group) ||
        (gather16 && bytes != 2 && source1 < source2 + group &&
         source2 < source1 + index_group) ||
        (form == 0 && destination < source1 + index_group &&
         source1 < destination + group)) return false;
    for (unsigned index = cpu.sr[CSR_VSTART]; index < cpu.sr[CSR_VL]; index++)
    {
      if (!unmasked && !vector_mask_bit(0, index)) continue;
      uint64_t selected = form == 0 ?
          vector_element_read(source1, index, index_bytes) :
          form == 3 ? source1 : cpu.gpr[source1];
      vector_element_write(destination, index, bytes,
                           selected < maximum ?
                           vector_element_read(source2, selected, bytes) : 0);
    }
    cpu.sr[CSR_VSTART] = 0;
    vector_mark_dirty(false);
    cpu.csr_dirty = true;
    return true;
  }
  bool mask_prefix = function == 0x14 && form == 2 &&
      source1 >= 1 && source1 <= 3;
  bool iota = function == 0x14 && form == 2 && source1 == 16;
  bool element_index = function == 0x14 && form == 2 && source1 == 17 &&
      source2 == 0;
  if (mask_prefix || iota || element_index)
  {
    unsigned destination_group = mask_prefix ? 1 : group;
    if (!vector_group_valid(destination, destination_group) ||
        (!mask_prefix && !unmasked && destination == 0) ||
        ((mask_prefix || iota) && cpu.sr[CSR_VSTART]) ||
        (mask_prefix && (destination == source2 ||
                         (!unmasked && destination == 0))) ||
        (iota && source2 >= destination &&
         source2 < destination + destination_group)) return false;
    unsigned count = 0;
    bool seen = false;
    for (unsigned index = cpu.sr[CSR_VSTART]; index < cpu.sr[CSR_VL]; index++)
    {
      if (!unmasked && !vector_mask_bit(0, index)) continue;
      if (mask_prefix)
      {
        bool source_bit = vector_mask_bit(source2, index);
        bool result = !seen && (source1 == 3 ||
                      (source1 == 2 ? source_bit : !source_bit));
        uint8_t *mask_byte = &cpu.vreg[destination][index / 8];
        uint8_t bit = 1u << (index % 8);
        *mask_byte = (*mask_byte & ~bit) | (result ? bit : 0);
        seen |= source_bit;
      }
      else
      {
        vector_element_write(destination, index, bytes,
                             element_index ? index : count);
        if (iota) count += vector_mask_bit(source2, index);
      }
    }
    cpu.sr[CSR_VSTART] = 0;
    vector_mark_dirty(false);
    cpu.csr_dirty = true;
    return true;
  }
  if (function == 0x17 && form == 2)
  {
    if (!unmasked || cpu.sr[CSR_VSTART] ||
        !vector_group_valid(destination, group) ||
        !vector_group_valid(source2, group) ||
        (destination < source2 + group && source2 < destination + group) ||
        (source1 >= destination && source1 < destination + group) ||
        (source1 >= source2 && source1 < source2 + group)) return false;
    unsigned output_index = 0;
    for (unsigned index = 0; index < cpu.sr[CSR_VL]; index++)
    {
      if (!vector_mask_bit(source1, index)) continue;
      vector_element_write(destination, output_index++, bytes,
                           vector_element_read(source2, index, bytes));
    }
    cpu.sr[CSR_VSTART] = 0;
    vector_mark_dirty(false);
    cpu.csr_dirty = true;
    return true;
  }
  bool reduction = (form == 2 && function <= 7) ||
      (form == 0 && (function == 0x30 || function == 0x31));
  if (reduction)
  {
    bool wide = form == 0;
    unsigned result_bytes = wide ? bytes * 2 : bytes;
    if (cpu.sr[CSR_VSTART] || result_bytes > 8 ||
        !vector_group_valid(source2, group) ||
        (wide && source1 >= source2 && source1 < source2 + group)) return false;
    if (cpu.sr[CSR_VL])
    {
      unsigned operation = wide ? 0 : function == 0 ? 0 : function < 4 ?
          function + 8 : function;
      uint64_t accumulator = vector_element_read(source1, 0, result_bytes);
      for (unsigned index = 0; index < cpu.sr[CSR_VL]; index++)
      {
        if (!unmasked && !vector_mask_bit(0, index)) continue;
        uint64_t value = vector_element_read(source2, index, bytes);
        if (wide && (function & 1))
        {
          unsigned shift = 64 - bytes * 8;
          value = (uint64_t)((int64_t)(value << shift) >> shift);
        }
        accumulator = vector_integer_result(operation, accumulator, value,
                                            result_bytes * 8, false);
      }
      vector_element_write(destination, 0, result_bytes, accumulator);
    }
    cpu.sr[CSR_VSTART] = 0;
    vector_mark_dirty(false);
    cpu.csr_dirty = true;
    return true;
  }
  if (function == 0x12 && form == 2 && source1 >= 2 && source1 <= 7)
  {
    unsigned shift = 4 - source1 / 2;
    unsigned factor = 1u << shift;
    int encoded_lmul = vtype & 7;
    int lmul = encoded_lmul < 4 ? encoded_lmul : encoded_lmul - 8;
    int source_exponent = lmul - (int)shift;
    if (bytes < factor || source_exponent < -3) return false;
    unsigned source_bytes = bytes / factor;
    unsigned source_group = source_exponent > 0 ? 1u << source_exponent : 1;
    bool overlap = destination < source2 + source_group &&
        source2 < destination + group;
    if (!vector_group_valid(destination, group) ||
        !vector_group_valid(source2, source_group) ||
        (!unmasked && !destination) ||
        (overlap && (source_exponent < 0 ||
                     destination + group != source2 + source_group))) return false;
    uint8_t registers[32][16];
    memcpy(registers, cpu.vreg, sizeof(registers));
    for (unsigned index = cpu.sr[CSR_VSTART]; index < cpu.sr[CSR_VL]; index++)
    {
      if (!unmasked && !vector_mask_bit(0, index)) continue;
      uint64_t source = vector_snapshot_read(registers, source2, index, source_bytes);
      uint64_t result = source1 & 1 ?
          (uint64_t)vector_signed_value(source, source_bytes * 8) : source;
      vector_element_write(destination, index, bytes, result);
    }
    cpu.sr[CSR_VSTART] = 0;
    vector_mark_dirty(false);
    cpu.csr_dirty = true;
    return true;
  }
  if (function >= 0x2c && function <= 0x2f &&
      (form == 0 || form == 3 || form == 4))
  {
    unsigned source_bytes = bytes * 2;
    int encoded_lmul = vtype & 7;
    int lmul = encoded_lmul < 4 ? encoded_lmul : encoded_lmul - 8;
    int source_exponent = lmul + 1;
    if (source_bytes > 8 || source_exponent > 3) return false;
    unsigned source_group = source_exponent > 0 ? 1u << source_exponent : 1;
    bool overlap = destination < source2 + source_group &&
        source2 < destination + group;
    if (!vector_group_valid(destination, group) ||
        !vector_group_valid(source2, source_group) ||
        (form == 0 && !vector_group_valid(source1, group)) ||
        (form == 0 && source2 < source1 + group &&
         source1 < source2 + source_group) ||
        (!unmasked && !destination) ||
        (overlap && destination != source2)) return false;
    uint64_t scalar = form == 3 ? source1 : cpu.gpr[source1];
    for (unsigned index = cpu.sr[CSR_VSTART]; index < cpu.sr[CSR_VL]; index++)
    {
      if (!unmasked && !vector_mask_bit(0, index)) continue;
      uint64_t source = vector_element_read(source2, index, source_bytes);
      uint64_t shift = form == 0 ? vector_element_read(source1, index, bytes) : scalar;
      bool saturated = false;
      uint64_t result = function < 0x2e ? function & 1 ?
          (uint64_t)(vector_signed_value(source, source_bytes * 8) >>
                     (shift & (source_bytes * 8 - 1))) :
          source >> (shift & (source_bytes * 8 - 1)) :
          vector_clip_result(function & 1, source, shift,
                             bytes * 8, cpu.sr[CSR_VXRM] & 3, &saturated);
      vector_element_write(destination, index, bytes, result);
      if (saturated)
      {
        cpu.sr[CSR_VXSAT] = 1;
        cpu.sr[CSR_VCSR] = (cpu.sr[CSR_VXRM] << 1) | 1;
      }
    }
    cpu.sr[CSR_VSTART] = 0;
    vector_mark_dirty(false);
    cpu.csr_dirty = true;
    return true;
  }
  if (function >= 0x30 && function <= 0x3f && (form == 2 || form == 6))
  {
    bool multiply = function >= 0x38;
    bool accumulate = function >= 0x3c;
    bool wide_source = !multiply && (function & 4) != 0;
    bool left_signed = multiply ?
        (function == 0x3a || function == 0x3b || function == 0x3d || function == 0x3e) :
        (function & 1) != 0;
    bool right_signed = multiply ?
        (function == 0x3b || function == 0x3d || function == 0x3f) :
        (function & 1) != 0;
    unsigned result_bytes = bytes * 2;
    unsigned source_bytes = wide_source ? result_bytes : bytes;
    int encoded_lmul = vtype & 7;
    int lmul = encoded_lmul < 4 ? encoded_lmul : encoded_lmul - 8;
    int destination_exponent = lmul + 1;
    int source_exponent = lmul + (int)wide_source;
    if (function == 0x39 || (function == 0x3e && form == 2) ||
        result_bytes > 8 || destination_exponent > 3 ||
        source_exponent > 3) return false;
    unsigned destination_group = destination_exponent > 0 ?
        1u << destination_exponent : 1;
    unsigned source_group = source_exponent > 0 ? 1u << source_exponent : 1;
    bool source2_overlap = destination < source2 + source_group &&
        source2 < destination + destination_group;
    bool source1_overlap = destination < source1 + group &&
        source1 < destination + destination_group;
    if (!vector_group_valid(destination, destination_group) ||
        !vector_group_valid(source2, source_group) ||
        (form == 2 && !vector_group_valid(source1, group)) ||
        (wide_source && form == 2 && source2 < source1 + group &&
         source1 < source2 + source_group) ||
        (!unmasked && !destination) ||
        (source2_overlap && !wide_source &&
         (lmul < 0 || destination + destination_group != source2 + source_group)) ||
        (form == 2 && source1_overlap &&
         (lmul < 0 || destination + destination_group != source1 + group))) return false;
    uint8_t registers[32][16];
    memcpy(registers, cpu.vreg, sizeof(registers));
    uint64_t scalar = (uint64_t)(int64_t)(sword_t)cpu.gpr[source1];
    for (unsigned index = cpu.sr[CSR_VSTART]; index < cpu.sr[CSR_VL]; index++)
    {
      if (!unmasked && !vector_mask_bit(0, index)) continue;
      uint64_t source = vector_snapshot_read(registers, source2, index, source_bytes);
      uint64_t operand = form == 2 ?
          vector_snapshot_read(registers, source1, index, bytes) : scalar;
      __int128 left = left_signed ?
          vector_signed_value(source, source_bytes * 8) : source;
      __int128 right = right_signed ?
          vector_signed_value(operand, bytes * 8) :
          (operand & ((UINT64_C(1) << (bytes * 8)) - 1));
      __int128 result = multiply ? left * right +
          (accumulate ? vector_snapshot_read(registers, destination, index, result_bytes) : 0) :
          function & 2 ? left - right : left + right;
      vector_element_write(destination, index, result_bytes, (uint64_t)result);
    }
    cpu.sr[CSR_VSTART] = 0;
    vector_mark_dirty(false);
    cpu.csr_dirty = true;
    return true;
  }
  if ((function == 0x29 || function == 0x2b ||
       function == 0x2d || function == 0x2f) &&
      (form == 2 || form == 6))
  {
    if (!vector_group_valid(destination, group) ||
        !vector_group_valid(source2, group) ||
        (form == 2 && !vector_group_valid(source1, group)) ||
        (!unmasked && !destination)) return false;
    uint8_t registers[32][16];
    memcpy(registers, cpu.vreg, sizeof(registers));
    uint64_t scalar = (uint64_t)(int64_t)(sword_t)cpu.gpr[source1];
    for (unsigned index = cpu.sr[CSR_VSTART]; index < cpu.sr[CSR_VL]; index++)
    {
      if (!unmasked && !vector_mask_bit(0, index)) continue;
      uint64_t old = vector_snapshot_read(registers, destination, index, bytes);
      uint64_t source = vector_snapshot_read(registers, source2, index, bytes);
      uint64_t operand = form == 2 ?
          vector_snapshot_read(registers, source1, index, bytes) : scalar;
      uint64_t product = (function & 4 ? source : old) * operand;
      uint64_t addend = function & 4 ? old : source;
      uint64_t result = function & 2 ? addend - product : addend + product;
      vector_element_write(destination, index, bytes, result);
    }
    cpu.sr[CSR_VSTART] = 0;
    vector_mark_dirty(false);
    cpu.csr_dirty = true;
    return true;
  }
  bool integer = function == 0 || function == 0x02 || function == 0x03 ||
      (function >= 0x04 && function <= 0x07) ||
      (function >= 0x09 && function <= 0x0b) ||
      function == 0x25 || function == 0x28 || function == 0x29;
  integer &= form == 0 || form == 3 || form == 4;
  if (function == 0x02 || (function >= 0x04 && function <= 0x07)) integer &= form != 3;
  if (function == 0x03) integer &= form != 0;
  bool compare = function >= 0x18 && function <= 0x1f &&
      (form == 0 || form == 3 || form == 4);
  if (function == 0x1a || function == 0x1b) compare &= form != 3;
  if (function == 0x1e || function == 0x1f) compare &= form != 0;
  bool carry = function >= 0x10 && function <= 0x13 &&
      (form == 0 || form == 3 || form == 4) &&
      (!(function & 2) || form != 3) &&
      ((function & 1) || !unmasked);
  bool mask_logic = function >= 0x18 && function <= 0x1f && form == 2 && unmasked;
  bool muldiv = function >= 0x20 && function <= 0x27 && (form == 2 || form == 6);
  bool saturating = function >= 0x20 && function <= 0x23 &&
      (form == 0 || form == 4 || (form == 3 && function < 0x22));
  bool averaging = function >= 0x08 && function <= 0x0b &&
      (form == 2 || form == 6);
  bool scaling_shift = (function == 0x2a || function == 0x2b) &&
      (form == 0 || form == 3 || form == 4);
  bool fractional_multiply = function == 0x27 && (form == 0 || form == 4);
  bool move = unmasked && function == 0x17 && source2 == 0 &&
      (form == 0 || form == 3 || form == 4);
  bool merge = !unmasked && function == 0x17 && (form == 0 || form == 3 || form == 4);
  bool extract = unmasked && function == 0x10 && form == 2 && source1 == 0;
  if (!integer && !compare && !carry && !mask_logic && !muldiv && !saturating &&
      !averaging && !scaling_shift && !fractional_multiply && !move && !merge && !extract)
    return false;
  if (extract)
  {
    uint64_t value = vector_element_read(source2, 0, bytes);
    if (bytes < sizeof(word_t))
    {
      uint64_t sign = UINT64_C(1) << (bytes * 8 - 1);
      value = (value ^ sign) - sign;
    }
    if (destination) cpu.gpr[destination] = (word_t)value;
  }
  else
  {
    bool mask_result = compare || mask_logic || (carry && (function & 1));
    if ((!extract && !vector_group_valid(destination, mask_result ? 1 : group)) ||
        (!unmasked && !mask_result && destination == 0) ||
        (mask_result && !mask_logic && destination > source2 &&
         destination < source2 + group) ||
        (mask_result && form == 0 && destination > source1 &&
         destination < source1 + group) ||
        ((integer || compare || carry || muldiv || saturating || averaging ||
          scaling_shift || fractional_multiply || merge) &&
         !vector_group_valid(source2, group)) ||
        (mask_logic && !vector_group_valid(source2, 1)) ||
        ((form == 0 || (form == 2 && (muldiv || averaging))) &&
         !vector_group_valid(source1, group)) ||
        (mask_logic && !vector_group_valid(source1, 1))) return false;
    bool shift_immediate = form == 3 && (function == 0x25 || function == 0x28 ||
                                         function == 0x29 || scaling_shift);
    uint64_t scalar = form == 3 ? (shift_immediate ? source1 : SEXT(source1, 5))
        : (uint64_t)(int64_t)(sword_t)cpu.gpr[source1];
    for (unsigned index = cpu.sr[CSR_VSTART]; index < cpu.sr[CSR_VL]; index++)
    {
      bool mask_bit = vector_mask_bit(0, index);
      if (!unmasked && !merge && !carry && !mask_bit) continue;
      uint64_t value = (integer || compare || carry || muldiv || saturating ||
                        averaging || scaling_shift || fractional_multiply || merge) ?
          vector_element_read(source2, index, bytes) : 0;
      uint64_t operand = (form == 0 || (form == 2 && (muldiv || averaging))) ?
          vector_element_read(source1, index, bytes) : scalar;
      bool saturated = false;
      uint64_t result = muldiv ?
          vector_muldiv_result(function, value, operand, bytes * 8) : mask_logic ?
          vector_mask_logic_result(function, vector_mask_bit(source2, index),
                                   vector_mask_bit(source1, index)) : saturating ?
          vector_saturating_result(function, value, operand, bytes * 8, &saturated) :
          averaging || scaling_shift || fractional_multiply ?
          vector_rounded_fixed_result(function, value, operand, bytes * 8,
                                      cpu.sr[CSR_VXRM] & 3, &saturated) :
          integer || compare || carry ?
          vector_integer_result(function, value, operand, bytes * 8,
                                carry && !unmasked && mask_bit) :
          merge && !mask_bit ? value : operand;
      if (mask_result)
      {
        uint8_t *mask_byte = &cpu.vreg[destination][index / 8];
        uint8_t bit = 1u << (index % 8);
        *mask_byte = (*mask_byte & ~bit) | (result ? bit : 0);
      }
      else vector_element_write(destination, index, bytes, result);
      if (saturated)
      {
        cpu.sr[CSR_VXSAT] = 1;
        cpu.sr[CSR_VCSR] = (cpu.sr[CSR_VXRM] << 1) | 1;
      }
    }
  }
  cpu.sr[CSR_VSTART] = 0;
  vector_mark_dirty(false);
  cpu.csr_dirty = true;
  return true;
}

word_t riscv_vector_memory(uint32_t instruction, bool store)
{
  if (!riscv_vector_context_enabled() ||
      (instruction & 0x10000000u)) return MCA_ILLEGAL_INS;
  unsigned mop = (instruction >> 26) & 3;
  bool indexed = (mop & 1) != 0;
  bool strided = mop == 2;
  unsigned mode = (instruction >> 20) & 31;
  bool whole = mop == 0 && mode == 8;
  bool mask_transfer = mop == 0 && mode == 11;
  bool fof = !store && mop == 0 && mode == 16;
  unsigned fields = ((instruction >> 29) & 7) + 1;
  if (mop == 0 && !whole && !mask_transfer && !fof && mode)
    return MCA_ILLEGAL_INS;
  unsigned width = (instruction >> 12) & 7;
  if (width != 0 && width < 5) return MCA_ILLEGAL_INS;
  unsigned bytes = width ? 1u << (width - 4) : 1;
#ifndef CONFIG_RV64
  if (indexed && bytes == 8) return MCA_ILLEGAL_INS;
#endif
  unsigned vector_reg = (instruction >> 7) & 31;
  bool unmasked = (instruction & (1u << 25)) != 0;
  unsigned group;
  unsigned limit;
  unsigned data_bytes = bytes;
  if (whole)
  {
    group = ((instruction >> 29) & 7) + 1;
    if (!unmasked || (group != 1 && group != 2 && group != 4 && group != 8) ||
        (store && width != 0)) return MCA_ILLEGAL_INS;
    limit = group * 16 / bytes;
    if (cpu.sr[CSR_VSTART] >= limit) return MCA_ILLEGAL_INS;
    fields = 1;
  }
  else
  {
    word_t vtype = cpu.sr[CSR_VTYPE];
    unsigned maximum = vector_vlmax(vtype);
    if (!maximum || cpu.sr[CSR_VL] > maximum)
      return MCA_ILLEGAL_INS;
    if (mask_transfer)
    {
      if (fields != 1 || !unmasked || width != 0) return MCA_ILLEGAL_INS;
      group = 1;
      limit = (cpu.sr[CSR_VL] + 7) / 8;
    }
    else
    {
      unsigned sew_bytes = 1u << ((vtype >> 3) & 7);
      unsigned encoded_lmul = vtype & 7;
      unsigned lmul_eighths = encoded_lmul < 4 ? 8u << encoded_lmul :
          8u >> (8 - encoded_lmul);
      if (indexed) data_bytes = sew_bytes;
      unsigned emul_eighths = lmul_eighths * data_bytes / sew_bytes;
      if (!emul_eighths || emul_eighths > 64) return MCA_ILLEGAL_INS;
      group = emul_eighths < 8 ? 1 : emul_eighths / 8;
      if (group * fields > 8 || vector_reg + group * fields > 32)
        return MCA_ILLEGAL_INS;
      limit = cpu.sr[CSR_VL];
      if (indexed)
      {
        unsigned index_eighths = lmul_eighths * bytes / sew_bytes;
        if (!index_eighths || index_eighths > 64) return MCA_ILLEGAL_INS;
        unsigned index_group = index_eighths < 8 ? 1 : index_eighths / 8;
        if (!vector_group_valid(mode, index_group)) return MCA_ILLEGAL_INS;
        bool overlap = vector_reg < mode + index_group &&
            mode < vector_reg + group * fields;
        if (store && data_bytes != bytes && overlap)
          return MCA_ILLEGAL_INS;
        if (!store && overlap &&
            (fields != 1 || (data_bytes < bytes && vector_reg != mode) ||
             (data_bytes > bytes && (index_eighths < 8 ||
                                     vector_reg + group != mode + index_group))))
          return MCA_ILLEGAL_INS;
      }
    }
  }
  if (!vector_group_valid(vector_reg, group) ||
      (!unmasked && !store && !vector_reg))
    return MCA_ILLEGAL_INS;
  word_t base = cpu.gpr[(instruction >> 15) & 31];
  word_t stride = strided ? cpu.gpr[mode] : fields * data_bytes;
  vector_mark_dirty(false);
  cpu.csr_dirty = true;
  jmp_buf fof_target;
  jmp_buf *previous_target = exec_jmp_override;
  if (fof)
  {
    exec_jmp_override = &fof_target;
    int jump_value = nemu_setjmp(fof_target);
    if (jump_value)
    {
      exec_jmp_override = previous_target;
      cpu_bus_unwind();
      unsigned fault_index = cpu.sr[CSR_VSTART];
      if (fault_index && (cause == MCA_LOA_ADD_MIS || cause == MCA_LOA_ACC_FAU ||
                          cause == MCA_LOA_PAG_FAU || cause == MCA_LOA_GUEST_PAG_FAU))
      {
        cpu.sr[CSR_VL] = fault_index;
        cpu.sr[CSR_VSTART] = 0;
        return 0;
      }
      nemu_memory_longjmp(jump_value);
    }
  }
  for (unsigned index = cpu.sr[CSR_VSTART]; index < limit; index++)
  {
    cpu.sr[CSR_VSTART] = index;
    if (!unmasked && !vector_mask_bit(0, index)) continue;
    word_t segment_base = base + (indexed ? (word_t)vector_element_read(mode, index, bytes) :
                                index * stride);
    for (unsigned probe = fields > 1; ; probe = 0)
    {
      for (unsigned field = 0; field < fields; field++)
      {
        word_t address = segment_base + field * data_bytes;
        if (whole && (address & (data_bytes - 1)))
        {
          g_vaddr = address;
          exec_jmp_override = previous_target;
          return store ? MCA_STO_ADD_MIS : MCA_LOA_ADD_MIS;
        }
        if (probe)
        {
          if (vaddr_probe_vector(address, data_bytes, store))
          {
            g_vaddr = address;
            cause = store ? MCA_STO_ACC_FAU : MCA_LOA_ACC_FAU;
            nemu_memory_longjmp(store ? 24 : 23);
          }
        }
        else if (store)
        {
          uint64_t value = vector_element_read(vector_reg + field * group,
                                               index, data_bytes);
#ifndef CONFIG_RV64
          if (data_bytes == 8)
          {
            vaddr_check_store(address, 8);
            vaddr_write(address, 4, (word_t)value);
            vaddr_write(address + 4, 4, (word_t)(value >> 32));
          }
          else
#endif
            vaddr_write(address, data_bytes, (word_t)value);
        }
        else
        {
          uint64_t value;
#ifndef CONFIG_RV64
          if (data_bytes == 8)
          {
            (void)vaddr_probe_vector(address, 8, false);
            bool misaligned = (address & 7) != 0;
            value = (uint32_t)vaddr_read_piece(address, 4, 8, misaligned) |
                (uint64_t)(uint32_t)vaddr_read_piece(address + 4, 4, 8, misaligned) << 32;
          }
          else
#endif
            value = vaddr_read(address, data_bytes);
          vector_element_write(vector_reg + field * group, index, data_bytes, value);
        }
      }
      if (!probe) break;
    }
  }
  cpu.sr[CSR_VSTART] = 0;
  exec_jmp_override = previous_target;
  return 0;
}

void riscv_vector_csr_write(uint16_t csr, word_t value)
{
  switch (csr)
  {
  case CSR_VSTART: cpu.sr[CSR_VSTART] = value & 0x7f; break;
  case CSR_VXSAT: cpu.sr[CSR_VXSAT] = value & 1; break;
  case CSR_VXRM: cpu.sr[CSR_VXRM] = value & 3; break;
  case CSR_VCSR:
    cpu.sr[CSR_VXSAT] = value & 1;
    cpu.sr[CSR_VXRM] = (value >> 1) & 3;
    break;
  default: return;
  }
  cpu.sr[CSR_VCSR] = (cpu.sr[CSR_VXRM] << 1) | cpu.sr[CSR_VXSAT];
  vector_mark_dirty(false);
}

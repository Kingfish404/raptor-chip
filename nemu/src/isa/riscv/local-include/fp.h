#ifndef __RISCV_FP_H__
#define __RISCV_FP_H__

#include <stdbool.h>
#include <stdint.h>

uint64_t riscv_fp_box_s(uint32_t bits);
uint64_t riscv_fp_box_h(uint16_t bits);
uint32_t riscv_fp_s_bits(uint64_t bits);
uint16_t riscv_fp_h_bits(uint64_t bits);
uint32_t riscv_fp_read_s(uint64_t bits);
uint16_t riscv_fp_read_h(uint64_t bits);
uint64_t riscv_fp_sgnj(uint64_t lhs, uint64_t rhs, unsigned mode);
uint32_t riscv_fp_add_s(uint32_t lhs, uint32_t rhs, unsigned rm, uint32_t *flags);
uint32_t riscv_fp_sub_s(uint32_t lhs, uint32_t rhs, unsigned rm, uint32_t *flags);
uint32_t riscv_fp_mul_s(uint32_t lhs, uint32_t rhs, unsigned rm, uint32_t *flags);
uint32_t riscv_fp_div_s(uint32_t lhs, uint32_t rhs, unsigned rm, uint32_t *flags);
uint32_t riscv_fp_sqrt_s(uint32_t operand, unsigned rm, uint32_t *flags);
uint32_t riscv_fp_fma_s(uint32_t lhs, uint32_t rhs, uint32_t addend, unsigned rm,
						bool negate_product, bool negate_addend, uint32_t *flags);
uint32_t riscv_fp_min_s(uint32_t lhs, uint32_t rhs, uint32_t *flags);
uint32_t riscv_fp_max_s(uint32_t lhs, uint32_t rhs, uint32_t *flags);
uint32_t riscv_fp_le_s(uint32_t lhs, uint32_t rhs, uint32_t *flags);
uint32_t riscv_fp_lt_s(uint32_t lhs, uint32_t rhs, uint32_t *flags);
uint32_t riscv_fp_eq_s(uint32_t lhs, uint32_t rhs, uint32_t *flags);
uint32_t riscv_fp_class_s(uint32_t bits);
uint64_t riscv_fp_add_d(uint64_t lhs, uint64_t rhs, unsigned rm, uint32_t *flags);
uint64_t riscv_fp_sub_d(uint64_t lhs, uint64_t rhs, unsigned rm, uint32_t *flags);
uint64_t riscv_fp_mul_d(uint64_t lhs, uint64_t rhs, unsigned rm, uint32_t *flags);
uint64_t riscv_fp_div_d(uint64_t lhs, uint64_t rhs, unsigned rm, uint32_t *flags);
uint64_t riscv_fp_sqrt_d(uint64_t operand, unsigned rm, uint32_t *flags);
uint64_t riscv_fp_fma_d(uint64_t lhs, uint64_t rhs, uint64_t addend, unsigned rm,
						bool negate_product, bool negate_addend, uint32_t *flags);
uint64_t riscv_fp_min_d(uint64_t lhs, uint64_t rhs, uint32_t *flags);
uint64_t riscv_fp_max_d(uint64_t lhs, uint64_t rhs, uint32_t *flags);
uint32_t riscv_fp_le_d(uint64_t lhs, uint64_t rhs, uint32_t *flags);
uint32_t riscv_fp_lt_d(uint64_t lhs, uint64_t rhs, uint32_t *flags);
uint32_t riscv_fp_eq_d(uint64_t lhs, uint64_t rhs, uint32_t *flags);
uint32_t riscv_fp_class_d(uint64_t bits);
uint64_t riscv_fp_to_int_s(uint32_t bits, unsigned rm, bool unsigned_result,
						   bool int64, uint32_t *flags);
uint64_t riscv_fp_to_int_d(uint64_t bits, unsigned rm, bool unsigned_result,
						   bool int64, uint32_t *flags);
uint32_t riscv_int_to_fp_s(uint64_t value, unsigned rm, bool unsigned_input,
						   bool int64, uint32_t *flags);
uint64_t riscv_int_to_fp_d(uint64_t value, unsigned rm, bool unsigned_input,
						   bool int64, uint32_t *flags);
uint32_t riscv_fp_convert_d_to_s(uint64_t bits, unsigned rm, uint32_t *flags);
uint64_t riscv_fp_convert_s_to_d(uint32_t bits, unsigned rm, uint32_t *flags);
uint32_t riscv_fp_convert_h_to_s(uint16_t bits, uint32_t *flags);
uint64_t riscv_fp_convert_h_to_d(uint16_t bits, uint32_t *flags);
uint16_t riscv_fp_convert_s_to_h(uint32_t bits, unsigned rm, uint32_t *flags);
uint16_t riscv_fp_convert_d_to_h(uint64_t bits, unsigned rm, uint32_t *flags);

#endif

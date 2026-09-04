#ifndef __RISCV_FP_EXEC_H__
#define __RISCV_FP_EXEC_H__

#include <common.h>
#include <cpu/decode.h>
#include <stdbool.h>
#include <stdint.h>

typedef uint32_t (*fp_binary_s_fn)(uint32_t, uint32_t, unsigned, uint32_t *);
typedef uint64_t (*fp_binary_d_fn)(uint64_t, uint64_t, unsigned, uint32_t *);
typedef uint32_t (*fp_unary_s_fn)(uint32_t, unsigned, uint32_t *);
typedef uint64_t (*fp_unary_d_fn)(uint64_t, unsigned, uint32_t *);
typedef uint32_t (*fp_minmax_s_fn)(uint32_t, uint32_t, uint32_t *);
typedef uint64_t (*fp_minmax_d_fn)(uint64_t, uint64_t, uint32_t *);
typedef uint32_t (*fp_compare_s_fn)(uint32_t, uint32_t, uint32_t *);
typedef uint32_t (*fp_compare_d_fn)(uint64_t, uint64_t, uint32_t *);

int fp_rs1(const Decode *s);
int fp_rs2(const Decode *s);
int fp_rs3(const Decode *s);
void fp_load_s(Decode *s, int rd, vaddr_t addr);
void fp_load_d(Decode *s, int rd, vaddr_t addr);
void fp_load_h(Decode *s, int rd, vaddr_t addr);
void fp_store_s(Decode *s, vaddr_t addr, int rs2);
void fp_store_d(Decode *s, vaddr_t addr, int rs2);
void fp_store_h(Decode *s, vaddr_t addr, int rs2);
void fp_move_to_s(Decode *s, int rd, word_t value);
void fp_move_from_s(Decode *s, int rd, int rs1);
void fp_move_to_d(Decode *s, int rd, word_t value);
void fp_move_from_d(Decode *s, int rd, int rs1);
void fp_move_to_h(Decode *s, int rd, word_t value);
void fp_move_from_h(Decode *s, int rd, int rs1);
void fp_sign_inject_s(Decode *s, int rd, int rs1, int rs2, unsigned mode);
void fp_sign_inject_d(Decode *s, int rd, int rs1, int rs2, unsigned mode);
void fp_exec_binary_s(Decode *s, int rd, int rs1, int rs2, fp_binary_s_fn operation);
void fp_exec_binary_d(Decode *s, int rd, int rs1, int rs2, fp_binary_d_fn operation);
void fp_exec_unary_s(Decode *s, int rd, int rs1, fp_unary_s_fn operation);
void fp_exec_unary_d(Decode *s, int rd, int rs1, fp_unary_d_fn operation);
void fp_exec_fma_s(Decode *s, int rd, int rs1, int rs2, int rs3,
                   bool negate_product, bool negate_addend);
void fp_exec_fma_d(Decode *s, int rd, int rs1, int rs2, int rs3,
                   bool negate_product, bool negate_addend);
void fp_exec_minmax_s(Decode *s, int rd, int rs1, int rs2, fp_minmax_s_fn operation);
void fp_exec_minmax_d(Decode *s, int rd, int rs1, int rs2, fp_minmax_d_fn operation);
void fp_exec_compare_s(Decode *s, int rd, int rs1, int rs2, fp_compare_s_fn operation);
void fp_exec_compare_d(Decode *s, int rd, int rs1, int rs2, fp_compare_d_fn operation);
void fp_exec_class_s(Decode *s, int rd, int rs1);
void fp_exec_class_d(Decode *s, int rd, int rs1);
void fp_exec_to_int_s(Decode *s, int rd, int rs1, bool unsigned_result, bool int64);
void fp_exec_to_int_d(Decode *s, int rd, int rs1, bool unsigned_result, bool int64);
void fp_exec_from_int_s(Decode *s, int rd, word_t value, bool unsigned_input, bool int64);
void fp_exec_from_int_d(Decode *s, int rd, word_t value, bool unsigned_input, bool int64);
void fp_exec_convert_d_to_s(Decode *s, int rd, int rs1);
void fp_exec_convert_s_to_d(Decode *s, int rd, int rs1);
void fp_exec_convert_h_to_s(Decode *s, int rd, int rs1);
void fp_exec_convert_h_to_d(Decode *s, int rd, int rs1);
void fp_exec_convert_s_to_h(Decode *s, int rd, int rs1);
void fp_exec_convert_d_to_h(Decode *s, int rd, int rs1);

#endif

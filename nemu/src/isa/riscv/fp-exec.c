#include "local-include/fp-exec.h"
#include "local-include/fp.h"
#include "local-include/reg.h"
#include <isa-def.h>
#include <cpu/cpu.h>
#include <cpu/difftest.h>
#include <memory/vaddr.h>

#define R(i) gpr(i)
#define CSR(i) sr(i)

static inline bool fp_access(Decode *s, bool double_precision)
{
    word_t misa = CSR(CSR_MISA);
    word_t fs = (CSR(CSR_MSTATUS) & CSR_MSTATUS_FS_MASK) >> 13;
    word_t required = CSR_MISA_EXT_F | (double_precision ? CSR_MISA_EXT_D : 0);
    if ((misa & required) != required || fs == 0)
    {
        s->dnpc = isa_raise_intr(MCA_ILLEGAL_INS, s->pc);
        difftest_skip_ref();
        return false;
    }
    return true;
}

static inline bool fp_rm_valid(unsigned rm)
{
    if (rm == 7)
        rm = (unsigned)((CSR(CSR_FCSR) >> 5) & 0x7);
    return rm <= 4;
}

static inline unsigned fp_rm_resolve(unsigned rm)
{
    return rm == 7 ? (unsigned)((CSR(CSR_FCSR) >> 5) & 0x7) : rm;
}

static inline void fp_mark_dirty(void)
{
    CSR(CSR_MSTATUS) = (CSR(CSR_MSTATUS) & ~CSR_MSTATUS_FS_MASK) | ((word_t)3 << 13);
}

static inline void fp_merge_flags(uint32_t flags)
{
    CSR(CSR_FCSR) = (CSR(CSR_FCSR) & ~(word_t)0x1f) | ((CSR(CSR_FCSR) | flags) & 0x1f);
    fp_mark_dirty();
}

static inline uint64_t fp_read_d_mem(vaddr_t addr)
{
#ifdef CONFIG_RV64
    return (uint64_t)vaddr_read(addr, 8);
#else
    uint64_t lo = (uint32_t)vaddr_read(addr, 4);
    uint64_t hi = (uint32_t)vaddr_read(addr + 4, 4);
    return lo | (hi << 32);
#endif
}

static inline void fp_write_d_mem(vaddr_t addr, uint64_t data)
{
#ifdef CONFIG_RV64
    vaddr_write(addr, 8, (word_t)data);
#else
    vaddr_write(addr, 4, (word_t)data);
    vaddr_write(addr + 4, 4, (word_t)(data >> 32));
#endif
}

static inline void fp_trap(Decode *s)
{
    s->dnpc = isa_raise_intr(MCA_ILLEGAL_INS, s->pc);
    difftest_skip_ref();
}

static inline bool fp_prepare(Decode *s, bool double_precision, unsigned *rm)
{
    *rm = BITS(s->isa.inst, 14, 12);
    if (!fp_rm_valid(*rm))
    {
        fp_trap(s);
        return false;
    }
    return fp_access(s, double_precision);
}

int fp_rs1(const Decode *s) { return BITS(s->isa.inst, 19, 15); }
int fp_rs2(const Decode *s) { return BITS(s->isa.inst, 24, 20); }
int fp_rs3(const Decode *s) { return BITS(s->isa.inst, 31, 27); }

void fp_load_s(Decode *s, int rd, vaddr_t addr)
{
    if (fp_access(s, false))
    {
        fpr(rd) = riscv_fp_box_s((uint32_t)vaddr_read(addr, 4));
        fp_mark_dirty();
    }
}

void fp_load_d(Decode *s, int rd, vaddr_t addr)
{
    if (fp_access(s, true))
    {
        fpr(rd) = fp_read_d_mem(addr);
        fp_mark_dirty();
    }
}

void fp_store_s(Decode *s, vaddr_t addr, int rs2)
{
    if (fp_access(s, false))
        vaddr_write(addr, 4, riscv_fp_s_bits(fpr(rs2)));
}

void fp_store_d(Decode *s, vaddr_t addr, int rs2)
{
    if (fp_access(s, true))
        fp_write_d_mem(addr, fpr(rs2));
}

void fp_move_to_s(Decode *s, int rd, word_t value)
{
    if (fp_access(s, false))
    {
        fpr(rd) = riscv_fp_box_s((uint32_t)value);
        fp_mark_dirty();
    }
}

void fp_move_from_s(Decode *s, int rd, int rs1)
{
    if (fp_access(s, false))
        R(rd) = SEXT(riscv_fp_s_bits(fpr(rs1)), 32);
}

void fp_move_to_d(Decode *s, int rd, word_t value)
{
    if (fp_access(s, true))
    {
        fpr(rd) = (uint64_t)value;
        fp_mark_dirty();
    }
}

void fp_move_from_d(Decode *s, int rd, int rs1)
{
    if (fp_access(s, true))
        R(rd) = fpr(rs1);
}

void fp_sign_inject_s(Decode *s, int rd, int rs1, int rs2, unsigned mode)
{
    if (fp_access(s, false))
    {
        fpr(rd) = riscv_fp_sgnj(fpr(rs1), fpr(rs2), mode);
        fp_mark_dirty();
    }
}

void fp_sign_inject_d(Decode *s, int rd, int rs1, int rs2, unsigned mode)
{
    if (fp_access(s, true))
    {
        uint64_t sign = fpr(rs2) & UINT64_C(0x8000000000000000);
        if (mode == 1)
            sign = (~fpr(rs2)) & UINT64_C(0x8000000000000000);
        else if (mode == 2)
            sign = (fpr(rs1) ^ fpr(rs2)) & UINT64_C(0x8000000000000000);
        fpr(rd) = (fpr(rs1) & UINT64_C(0x7fffffffffffffff)) | sign;
        fp_mark_dirty();
    }
}

void fp_exec_binary_s(Decode *s, int rd, int rs1, int rs2, fp_binary_s_fn operation)
{
    unsigned rm;
    if (fp_prepare(s, false, &rm))
    {
        uint32_t flags = 0;
        fpr(rd) = riscv_fp_box_s(operation(riscv_fp_read_s(fpr(rs1)), riscv_fp_read_s(fpr(rs2)),
                                           fp_rm_resolve(rm), &flags));
        fp_merge_flags(flags);
    }
}

void fp_exec_binary_d(Decode *s, int rd, int rs1, int rs2, fp_binary_d_fn operation)
{
    unsigned rm;
    if (fp_prepare(s, true, &rm))
    {
        uint32_t flags = 0;
        fpr(rd) = operation(fpr(rs1), fpr(rs2), fp_rm_resolve(rm), &flags);
        fp_merge_flags(flags);
    }
}

void fp_exec_unary_s(Decode *s, int rd, int rs1, fp_unary_s_fn operation)
{
    unsigned rm;
    if (fp_prepare(s, false, &rm))
    {
        uint32_t flags = 0;
        fpr(rd) = riscv_fp_box_s(operation(riscv_fp_read_s(fpr(rs1)), fp_rm_resolve(rm), &flags));
        fp_merge_flags(flags);
    }
}

void fp_exec_unary_d(Decode *s, int rd, int rs1, fp_unary_d_fn operation)
{
    unsigned rm;
    if (fp_prepare(s, true, &rm))
    {
        uint32_t flags = 0;
        fpr(rd) = operation(fpr(rs1), fp_rm_resolve(rm), &flags);
        fp_merge_flags(flags);
    }
}

void fp_exec_fma_s(Decode *s, int rd, int rs1, int rs2, int rs3,
                   bool negate_product, bool negate_addend)
{
    unsigned rm;
    if (fp_prepare(s, false, &rm))
    {
        uint32_t flags = 0;
        fpr(rd) = riscv_fp_box_s(riscv_fp_fma_s(riscv_fp_read_s(fpr(rs1)),
                                                riscv_fp_read_s(fpr(rs2)),
                                                riscv_fp_read_s(fpr(rs3)), fp_rm_resolve(rm),
                                                negate_product, negate_addend, &flags));
        fp_merge_flags(flags);
    }
}

void fp_exec_fma_d(Decode *s, int rd, int rs1, int rs2, int rs3,
                   bool negate_product, bool negate_addend)
{
    unsigned rm;
    if (fp_prepare(s, true, &rm))
    {
        uint32_t flags = 0;
        fpr(rd) = riscv_fp_fma_d(fpr(rs1), fpr(rs2), fpr(rs3), fp_rm_resolve(rm),
                                 negate_product, negate_addend, &flags);
        fp_merge_flags(flags);
    }
}

void fp_exec_minmax_s(Decode *s, int rd, int rs1, int rs2, fp_minmax_s_fn operation)
{
    if (fp_access(s, false))
    {
        uint32_t flags = 0;
        fpr(rd) = riscv_fp_box_s(operation(riscv_fp_read_s(fpr(rs1)), riscv_fp_read_s(fpr(rs2)), &flags));
        fp_merge_flags(flags);
    }
}

void fp_exec_minmax_d(Decode *s, int rd, int rs1, int rs2, fp_minmax_d_fn operation)
{
    if (fp_access(s, true))
    {
        uint32_t flags = 0;
        fpr(rd) = operation(fpr(rs1), fpr(rs2), &flags);
        fp_merge_flags(flags);
    }
}

void fp_exec_compare_s(Decode *s, int rd, int rs1, int rs2, fp_compare_s_fn operation)
{
    if (fp_access(s, false))
    {
        uint32_t flags = 0;
        R(rd) = operation(riscv_fp_read_s(fpr(rs1)), riscv_fp_read_s(fpr(rs2)), &flags);
        if (flags)
            fp_merge_flags(flags);
    }
}

void fp_exec_compare_d(Decode *s, int rd, int rs1, int rs2, fp_compare_d_fn operation)
{
    if (fp_access(s, true))
    {
        uint32_t flags = 0;
        R(rd) = operation(fpr(rs1), fpr(rs2), &flags);
        if (flags)
            fp_merge_flags(flags);
    }
}

void fp_exec_class_s(Decode *s, int rd, int rs1)
{
    if (fp_access(s, false))
        R(rd) = riscv_fp_class_s(riscv_fp_read_s(fpr(rs1)));
}

void fp_exec_class_d(Decode *s, int rd, int rs1)
{
    if (fp_access(s, true))
        R(rd) = riscv_fp_class_d(fpr(rs1));
}

void fp_exec_to_int_s(Decode *s, int rd, int rs1, bool unsigned_result, bool int64)
{
    unsigned rm;
    if (fp_prepare(s, false, &rm))
    {
        uint32_t flags = 0;
        uint64_t value = riscv_fp_to_int_s(riscv_fp_read_s(fpr(rs1)), fp_rm_resolve(rm),
                                           unsigned_result, int64, &flags);
        R(rd) = int64 ? value : SEXT((uint32_t)value, 32);
        if (flags)
            fp_merge_flags(flags);
    }
}

void fp_exec_to_int_d(Decode *s, int rd, int rs1, bool unsigned_result, bool int64)
{
    unsigned rm;
    if (fp_prepare(s, true, &rm))
    {
        uint32_t flags = 0;
        uint64_t value = riscv_fp_to_int_d(fpr(rs1), fp_rm_resolve(rm), unsigned_result, int64, &flags);
        R(rd) = int64 ? value : SEXT((uint32_t)value, 32);
        if (flags)
            fp_merge_flags(flags);
    }
}

void fp_exec_from_int_s(Decode *s, int rd, word_t value,
                        bool unsigned_input, bool int64)
{
    unsigned rm;
    if (fp_prepare(s, false, &rm))
    {
        uint32_t flags = 0;
        fpr(rd) = riscv_fp_box_s(riscv_int_to_fp_s(value, fp_rm_resolve(rm),
                                                   unsigned_input, int64, &flags));
        fp_merge_flags(flags);
    }
}

void fp_exec_from_int_d(Decode *s, int rd, word_t value,
                        bool unsigned_input, bool int64)
{
    unsigned rm;
    if (fp_prepare(s, true, &rm))
    {
        uint32_t flags = 0;
        fpr(rd) = riscv_int_to_fp_d(value, fp_rm_resolve(rm), unsigned_input, int64, &flags);
        fp_merge_flags(flags);
    }
}

void fp_exec_convert_d_to_s(Decode *s, int rd, int rs1)
{
    unsigned rm;
    if (fp_prepare(s, true, &rm))
    {
        uint32_t flags = 0;
        fpr(rd) = riscv_fp_box_s(riscv_fp_convert_d_to_s(fpr(rs1), fp_rm_resolve(rm), &flags));
        fp_merge_flags(flags);
    }
}

void fp_exec_convert_s_to_d(Decode *s, int rd, int rs1)
{
    unsigned rm;
    if (fp_prepare(s, true, &rm))
    {
        uint32_t flags = 0;
        fpr(rd) = riscv_fp_convert_s_to_d(riscv_fp_read_s(fpr(rs1)), fp_rm_resolve(rm), &flags);
        fp_merge_flags(flags);
    }
}

#undef CSR
#undef R

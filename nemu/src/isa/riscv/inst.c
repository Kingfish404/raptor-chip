/***************************************************************************************
 * Copyright (c) 2014-2022 Zihao Yu, Nanjing University
 *
 * NEMU is licensed under Mulan PSL v2.
 * You can use this software according to the terms and conditions of the Mulan PSL v2.
 * You may obtain a copy of Mulan PSL v2 at:
 *          http://license.coscl.org.cn/MulanPSL2
 *
 * THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND,
 * EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT,
 * MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
 *
 * See the Mulan PSL v2 for more details.
 ***************************************************************************************/

#include <setjmp.h>
#include "local-include/reg.h"
#include <isa-def.h>
#include <cpu/cpu.h>
#include <cpu/ifetch.h>
#include <cpu/decode.h>
#include <cpu/difftest.h>
#include <cpu/icache.h>
#include <memory/tlb.h>

#define R(i) gpr(i)
#define CSR(i) sr(i)
/* CSR write with PMP hook: routes writes to pmpcfg/pmpaddr through
 * pmp_csr_write() which enforces WARL masking and L-bit lockdown.  All
 * other CSRs fall through to the raw cpu.sr[] store. */
int pmp_csr_write(uint16_t csr, word_t val);
/* WARL coercion for tvec/epc CSRs, mirroring rapt_csr.sv:
 *   - mtvec/stvec: if wdata[1]==1 (reserved MODE 10/11), mode bits -> 00.
 *   - mepc/sepc:   bit 0 always 0 (IALIGN enforcement).
 *   - satp:        if MODE field is unsupported, the entire write is dropped
 *                  (caller must check the rejection flag). */
static inline bool csrw_satp_accept(word_t v)
{
#ifdef CONFIG_RV64
  /* RV64: MODE is bits [63:60].  Accept Bare(0) or Sv39(8) only. */
  uint32_t mode = (uint32_t)((v >> 60) & 0xf);
  return (mode == 0) || (mode == 8);
#else
  /* RV32: MODE is bit [31].  Both 0 (Bare) and 1 (Sv32) are valid. */
  (void)v;
  return true;
#endif
}
static inline word_t csrw_warl(uint16_t c, word_t v)
{
  c &= 0xfff;
  if (c == CSR_MTVEC || c == CSR_STVEC)
  {
    return (v & ~(word_t)0x3) | ((v & 0x2) ? 0 : (v & 0x3));
  }
  if (c == CSR_MEPC || c == CSR_SEPC)
  {
    return v & ~(word_t)0x1;
  }
  if (c == CSR_SENVCFG)
  {
    return v & (word_t)0x70;
  }
  if (c == CSR_MENVCFG)
  {
#ifdef CONFIG_RV64
    return v & ((word_t)0x8000000000000000ull | (word_t)0x70);
#else
    return v & (word_t)0x70;
#endif
  }
  return v;
}
#define CSRW(i, v)                                                         \
  do                                                                       \
  {                                                                        \
    uint16_t _c = (uint16_t)((i) & 0xfff);                                 \
    word_t _v = csrw_warl(_c, (word_t)(v));                                \
    /* satp WARL: drop entire write if MODE is unsupported (Priv §10.6.1). */ \
    if (_c == CSR_SATP && !csrw_satp_accept(_v))                           \
    {                                                                      \
      cpu.last_csr_wr = _c;                                                \
      break;                                                               \
    }                                                                      \
    if (!pmp_csr_write(_c, _v))                                            \
    {                                                                      \
      if (_c == CSR_MIP)                                                   \
        sr(_c) = (sr(_c) & ~(word_t)0x222) | (_v & (word_t)0x222);         \
      else                                                                 \
        sr(_c) = _v;                                                       \
    }                                                                      \
    cpu.last_csr_wr = _c;                                                  \
    /* Flush soft TLB on writes to CSRs that affect address translation */ \
    if (_c == CSR_SATP || _c == CSR_MSTATUS || _c == CSR_SSTATUS ||        \
        _c == CSR_MSTATUSH)                                                \
      soft_tlb_flush();                                                    \
  } while (0)
#define Mr vaddr_read
#define Mw vaddr_write

#ifdef CONFIG_RV64
typedef __int128 dword_t;
typedef unsigned __int128 udword_t;
#define MULH_SHIFT 64
#else
typedef int64_t dword_t;
typedef uint64_t udword_t;
#define MULH_SHIFT 32
#endif

uint64_t get_mtimecmp();
uint64_t get_time();
word_t get_paddr(vaddr_t addr, int len);
void clint_update_mip(void);
bool clint_wfi_advance(void);
extern uint64_t g_nr_guest_inst;

void ftrace_add(word_t pc, word_t npc, word_t inst);

bool csr_valid(Decode *s, uint16_t csr, bool is_write)
{
  csr = csr & 0xfff;
  // Privilege check: CSR addr[9:8] encodes minimum privilege level
  uint8_t csr_priv = (csr >> 8) & 0x3;
  if (csr_priv > cpu.priv)
  {
    s->dnpc = isa_raise_intr(MCA_ILLEGAL_INS, s->pc);
    difftest_skip_ref();
    return false;
  }
  // Read-only check: CSR addr[11:10]==2'b11 means read-only
  if (is_write && ((csr >> 10) & 0x3) == 0x3)
  {
    s->dnpc = isa_raise_intr(MCA_ILLEGAL_INS, s->pc);
    difftest_skip_ref();
    return false;
  }
  // TVM: if mstatus.TVM=1 and priv==S, access to satp traps illegal-instruction.
  if (csr == CSR_SATP && cpu.priv == PRV_S)
  {
    csr_t ms = {.val = cpu.sr[CSR_MSTATUS]};
    if (ms.mstatus.tvm)
    {
      s->dnpc = isa_raise_intr(MCA_ILLEGAL_INS, s->pc);
      difftest_skip_ref();
      return false;
    }
  }
  // PMP CSRs are fully implemented in system/pmp.c; no special-case needed
  // here.  Writes are routed through pmp_csr_write() below.

  CSR_status csr_status = check_csr_exist(csr);
  switch (csr_status)
  {
  case CSR_EXIST:
    return true;
    break;
  case CSR_EXIST_DIFF_SKIP:
    difftest_skip_ref();
    return true;
    break;
  case CSR_NOT_EXIST:
    s->dnpc = isa_raise_intr(MCA_ILLEGAL_INS, s->pc);
    difftest_skip_ref();
    break;
  default:
    panic("Wrong csr_status");
    break;
  }
  return false;
}

static void decode_operand(Decode *s, int *rd, int *rs, word_t *src1, word_t *src2, word_t *imm, int type)
{
  uint32_t i = s->isa.inst;
  uint32_t rs1 = BITS(i, 19, 15);
  uint32_t rs2 = BITS(i, 24, 20);
  *rd = BITS(i, 11, 7);
  *rs = rs1;
  switch (type)
  {
  case TYPE_R:
    src1R();
    src2R();
    break;
  case TYPE_I:
    src1R();
    immI();
    break;
  case TYPE_I_I:
    *src1 = rs1;
    immI();
    break;
  case TYPE_S:
    src1R();
    src2R();
    immS();
    break;
  case TYPE_B:
    src1R();
    src2R();
    immB();
    break;
  case TYPE_U:
    immU();
    break;
  case TYPE_J:
    immJ();
    break;
  case TYPE_N:
    break;
  default:
    panic("unsupported type = %d", type);
  }
}

/*
    31       27   25 24     20 19     15 14  12 11     7 6      0
    |  funct7       |   rs2   |   rs1   |funct3|  rd    | opcode | R-type
    |  [11:0]                 |   rs1   |funct3|  rd    | opcode | I-type
    |  [11:5]       |   rs2   |   rs1   |funct3|   [4:0]| opcode | S-type
    |  [12|10:5]    |   rs2   |   rs1   |funct3|[4:1|11]| opcode | B-type
    |  [31:12]                                 |   rd   | opcode | U-type
    |  [20|10:1|11|19:12]                      |   rd   | opcode | J-type
 */
static int decode_exec(Decode *s)
{
  if ((s->isa.inst & 0x3) != 3)
  {
    s->isa.inst &= 0xffff;
    s->snpc = s->pc + 2;
    // uint32_t inst = s->isa.inst;
    uint32_t decompress_c(uint32_t inst);
    s->isa.inst = decompress_c(s->isa.inst);

    // char p[512];
    // void disassemble(char *str, int size, uint64_t pc, uint8_t *code, int nbyte);
    // disassemble(p, 512, s->pc, (uint8_t *)(&s->isa.inst), 4);
    // printf("[C2I] %08x: %04x -> %08x, %s\n", s->pc, inst, s->isa.inst, p);
  }
  else if (s->snpc <= s->pc)
  {
    /* Cache-miss path: inst_fetch advanced snpc to pc+4 already. On a
     * decode-cache hit the caller has pre-set snpc to pc+ilen, so we
     * must not clobber it here. */
    s->snpc = s->pc + 4;
  }
  s->dnpc = s->snpc;

#define INSTPAT_INST(s) ((s)->isa.inst)
#define INSTPAT_MATCH(s, name, type, ... /* execute body */)               \
  {                                                                        \
    int rd = 0, rs1 = 0;                                                   \
    word_t src1 = 0, src2 = 0, imm = 0;                                    \
    decode_operand(s, &rd, &rs1, &src1, &src2, &imm, concat(TYPE_, type)); \
    __VA_ARGS__;                                                           \
  }

  INSTPAT_SWITCH();
  //      |31      24rs2 19rs1 14  11 rd 6      0|
  INSTPAT_CASE(0b01101, grp_lui) // LUI
  INSTPAT("??????? ????? ????? ??? ????? 01101 11", lui, U, R(rd) = imm);
  INSTPAT_CASE_END(grp_lui)

  INSTPAT_CASE(0b00101, grp_auipc) // AUIPC
  INSTPAT("??????? ????? ????? ??? ????? 00101 11", auipc, U, R(rd) = s->pc + imm);
  INSTPAT_CASE_END(grp_auipc)

  INSTPAT_CASE(0b11011, grp_jal) // JAL
  INSTPAT("??????? ????? ????? ??? ????? 11011 11", jal, J, R(rd) = s->snpc; s->dnpc = (s->pc + imm) & ~1);
  INSTPAT_CASE_END(grp_jal)

  INSTPAT_CASE(0b11001, grp_jalr) // JALR
  INSTPAT("??????? ????? ????? 000 ????? 11001 11", jalr, I, R(rd) = s->snpc; s->dnpc = (src1 + imm) & ~1);
  INSTPAT_CASE_END(grp_jalr)

  INSTPAT_CASE(0b11000, grp_branch) // Branch
  INSTPAT("??????? ????? ????? 000 ????? 11000 11", beq, B, if (src1 == src2) s->dnpc = s->pc + imm);
  INSTPAT("??????? ????? ????? 001 ????? 11000 11", bne, B, if (src1 != src2) s->dnpc = s->pc + imm);
  INSTPAT("??????? ????? ????? 100 ????? 11000 11", blt, B, if ((sword_t)src1 < (sword_t)src2) s->dnpc = s->pc + imm);
  INSTPAT("??????? ????? ????? 101 ????? 11000 11", bge, B, if ((sword_t)src1 >= (sword_t)src2) s->dnpc = s->pc + imm);
  INSTPAT("??????? ????? ????? 110 ????? 11000 11", bltu, B, if ((word_t)src1 < (word_t)src2) s->dnpc = s->pc + imm);
  INSTPAT("??????? ????? ????? 111 ????? 11000 11", bgeu, B, if ((word_t)src1 >= (word_t)src2) s->dnpc = s->pc + imm);
  INSTPAT_CASE_END(grp_branch)

  INSTPAT_CASE(0b00000, grp_load) // Load
  INSTPAT("??????? ????? ????? 000 ????? 00000 11", lb, I, R(rd) = SEXT(Mr(src1 + imm, 1), 8));
  INSTPAT("??????? ????? ????? 001 ????? 00000 11", lh, I, R(rd) = SEXT(Mr(src1 + imm, 2), 16));
  INSTPAT("??????? ????? ????? 010 ????? 00000 11", lw, I, R(rd) = SEXT(Mr(src1 + imm, 4), 32));
  INSTPAT("??????? ????? ????? 100 ????? 00000 11", lbu, I, { R(rd) = Mr(src1 + imm, 1); });
  INSTPAT("??????? ????? ????? 101 ????? 00000 11", lhu, I, { R(rd) = Mr(src1 + imm, 2); });
#ifdef CONFIG_RV64
  // RV64I loads (RV32 leaves these encodings reserved → illegal-instruction)
  INSTPAT("??????? ????? ????? 110 ????? 00000 11", lwu, I, R(rd) = Mr(src1 + imm, 4));
  INSTPAT("??????? ????? ????? 011 ????? 00000 11", ld, I, R(rd) = Mr(src1 + imm, 8));
#endif
  INSTPAT_CASE_END(grp_load)

  INSTPAT_CASE(0b01000, grp_store) // Store
  INSTPAT("??????? ????? ????? 000 ????? 01000 11", sb, S, Mw(src1 + imm, 1, src2));
  INSTPAT("??????? ????? ????? 001 ????? 01000 11", sh, S, Mw(src1 + imm, 2, src2));
  INSTPAT("??????? ????? ????? 010 ????? 01000 11", sw, S, Mw(src1 + imm, 4, src2));
#ifdef CONFIG_RV64
  // RV64I store (RV32 reserved → illegal-instruction)
  INSTPAT("??????? ????? ????? 011 ????? 01000 11", sd, S, Mw(src1 + imm, 8, src2));
#endif
  INSTPAT_CASE_END(grp_store)

  INSTPAT_CASE(0b00100, grp_opimm) // OP-IMM
  INSTPAT("??????? ????? ????? 000 ????? 00100 11", addi, I, R(rd) = (sword_t)src1 + imm);
  INSTPAT("??????? ????? ????? 010 ????? 00100 11", slti, I, R(rd) = ((sword_t)src1 < (sword_t)imm) ? 1 : 0);
  INSTPAT("??????? ????? ????? 011 ????? 00100 11", sltiu, I, R(rd) = ((word_t)src1 < (word_t)imm) ? 1 : 0);
  INSTPAT("??????? ????? ????? 100 ????? 00100 11", xori, I, R(rd) = src1 ^ imm);
  INSTPAT("??????? ????? ????? 110 ????? 00100 11", ori, I, R(rd) = src1 | imm);
  INSTPAT("??????? ????? ????? 111 ????? 00100 11", andi, I, R(rd) = src1 & imm);
  INSTPAT("0000000 ????? ????? 001 ????? 00100 11", slli, I, R(rd) = src1 << (imm & 0x1f));
  INSTPAT("0000000 ????? ????? 101 ????? 00100 11", srli, I, R(rd) = ((word_t)src1) >> (imm & 0x1f));
  INSTPAT("0100000 ????? ????? 101 ????? 00100 11", srai, I, R(rd) = ((sword_t)src1) >> (imm & 0x1f));
  // RV64I shift-imm (overrides RV32 versions when CONFIG_RV64)
  INSTPAT("000000? ????? ????? 001 ????? 00100 11", slli, I, R(rd) = src1 << (imm & 0x3f));
  INSTPAT("000000? ????? ????? 101 ????? 00100 11", srli, I, R(rd) = (word_t)src1 >> (imm & 0x3f));
  INSTPAT("010000? ????? ????? 101 ????? 00100 11", srai, I, R(rd) = (sword_t)src1 >> (imm & 0x3f));

  // Zbb Extension (OP-IMM encoded)
  INSTPAT("0110000 00000 ????? 001 ????? 00100 11", clz, I, {
    word_t x = src1; unsigned count = sizeof(word_t) * 8;
    for (int i = sizeof(word_t) * 8 - 1; i >= 0; i--) { if ((x >> i) & 1) { count = sizeof(word_t) * 8 - 1 - i; break; } }
    R(rd) = count; });
  INSTPAT("0110000 00001 ????? 001 ????? 00100 11", ctz, I, {
    word_t x = src1; unsigned count = sizeof(word_t) * 8;
    for (unsigned i = 0; i < sizeof(word_t) * 8; i++) { if ((x >> i) & 1) { count = i; break; } }
    R(rd) = count; });
  INSTPAT("0110000 00010 ????? 001 ????? 00100 11", cpop, I, {
    word_t x = src1; unsigned count = 0;
    for (unsigned i = 0; i < sizeof(word_t) * 8; i++) { if ((x >> i) & 1) count++; }
    R(rd) = count; });
  INSTPAT("0110000 00100 ????? 001 ????? 00100 11", sext.b, I, R(rd) = SEXT(src1 & 0xff, 8));
  INSTPAT("0110000 00101 ????? 001 ????? 00100 11", sext.h, I, R(rd) = SEXT(src1 & 0xffff, 16));
#ifndef CONFIG_RV64
  INSTPAT("0110100 11000 ????? 101 ????? 00100 11", rev8, I, {
    word_t x = src1, result = 0;
    result |= (x & 0xff) << 24; result |= ((x >> 8) & 0xff) << 16;
    result |= ((x >> 16) & 0xff) << 8; result |= ((x >> 24) & 0xff);
    R(rd) = result; });
  INSTPAT("0110000 ????? ????? 101 ????? 00100 11", rori, I, {
    unsigned shamt = imm & 0x1f;
    R(rd) = ((word_t)src1 >> shamt) | (src1 << ((32 - shamt) & 31)); });

  // Zbs Extension (OP-IMM encoded, RV32)
  INSTPAT("0100100 ????? ????? 001 ????? 00100 11", bclri, I, R(rd) = src1 & ~((word_t)1 << (imm & 0x1f)));
  INSTPAT("0100100 ????? ????? 101 ????? 00100 11", bexti, I, R(rd) = ((word_t)src1 >> (imm & 0x1f)) & 1);
  INSTPAT("0110100 ????? ????? 001 ????? 00100 11", binvi, I, R(rd) = src1 ^ ((word_t)1 << (imm & 0x1f)));
  INSTPAT("0010100 ????? ????? 001 ????? 00100 11", bseti, I, R(rd) = src1 | ((word_t)1 << (imm & 0x1f)));
#else
  INSTPAT("0110101 11000 ????? 101 ????? 00100 11", rev8, I, {
    word_t x = src1, result = 0;
    for (int i = 0; i < 8; i++) result |= ((x >> (i * 8)) & 0xff) << ((7 - i) * 8);
    R(rd) = result; });
  INSTPAT("011000? ????? ????? 101 ????? 00100 11", rori, I, {
    unsigned shamt = imm & 0x3f;
    R(rd) = ((word_t)src1 >> shamt) | (src1 << ((64 - shamt) & 63)); });
  // Zbs Extension (OP-IMM encoded, RV64)
  INSTPAT("010010? ????? ????? 001 ????? 00100 11", bclri, I, R(rd) = src1 & ~((word_t)1 << (imm & 0x3f)));
  INSTPAT("010010? ????? ????? 101 ????? 00100 11", bexti, I, R(rd) = ((word_t)src1 >> (imm & 0x3f)) & 1);
  INSTPAT("011010? ????? ????? 001 ????? 00100 11", binvi, I, R(rd) = src1 ^ ((word_t)1 << (imm & 0x3f)));
  INSTPAT("001010? ????? ????? 001 ????? 00100 11", bseti, I, R(rd) = src1 | ((word_t)1 << (imm & 0x3f)));
#endif
  INSTPAT("0010100 00111 ????? 101 ????? 00100 11", orc.b, I, {
    word_t x = src1, result = 0;
    for (unsigned i = 0; i < sizeof(word_t); i++) {
      if ((x >> (i * 8)) & 0xff) result |= (word_t)0xff << (i * 8);
    }
    R(rd) = result; });
  INSTPAT_CASE_END(grp_opimm)

  INSTPAT_CASE(0b01100, grp_op) // OP + RV32M
  INSTPAT("0000000 ????? ????? 000 ????? 01100 11", add, R, R(rd) = src1 + src2);
  INSTPAT("0100000 ????? ????? 000 ????? 01100 11", sub, R, R(rd) = src1 - src2);
  INSTPAT("0000000 ????? ????? 001 ????? 01100 11", sll, R, R(rd) = src1 << (src2 & (sizeof(word_t) * 8 - 1)));
  INSTPAT("0000000 ????? ????? 010 ????? 01100 11", slt, R, R(rd) = (sword_t)src1 < (sword_t)src2);
  INSTPAT("0000000 ????? ????? 011 ????? 01100 11", sltu, R, R(rd) = ((word_t)src1 < (word_t)src2) ? 1 : 0);
  INSTPAT("0000000 ????? ????? 100 ????? 01100 11", xor, R, R(rd) = src1 ^ src2);
  INSTPAT("0000000 ????? ????? 101 ????? 01100 11", srl, R, R(rd) = src1 >> (src2 & (sizeof(word_t) * 8 - 1)));
  // SRA: arithmetic right shift requires signed operand so `>>` is arithmetic, not logical
  INSTPAT("0100000 ????? ????? 101 ????? 01100 11", sra, R, R(rd) = (sword_t)src1 >> (src2 & (sizeof(word_t) * 8 - 1)));
  INSTPAT("0000000 ????? ????? 110 ????? 01100 11", or, R, R(rd) = src1 | src2);
  INSTPAT("0000000 ????? ????? 111 ????? 01100 11", and, R, R(rd) = src1 & src2);
  // RV32M Extension
  INSTPAT("0000001 ????? ????? 000 ????? 01100 11", mul, R, R(rd) = src1 * src2);
  INSTPAT("0000001 ????? ????? 001 ????? 01100 11", mulh, R, R(rd) = ((dword_t)(sword_t)src1 * (dword_t)(sword_t)src2) >> MULH_SHIFT);
  INSTPAT("0000001 ????? ????? 010 ????? 01100 11", mulhsu, R, R(rd) = ((dword_t)(sword_t)src1 * (dword_t)(word_t)src2) >> MULH_SHIFT);
  INSTPAT("0000001 ????? ????? 011 ????? 01100 11", mulhu, R, R(rd) = ((udword_t)(word_t)src1 * (udword_t)(word_t)src2) >> MULH_SHIFT);
  // RISC-V spec: div-by-zero and signed overflow (INT_MIN/-1) have defined results
  INSTPAT("0000001 ????? ????? 100 ????? 01100 11", div, R,
          R(rd) = ((sword_t)src2 == 0)                                  ? (word_t)~0
                  : ((sword_t)src1 == INT32_MIN && (sword_t)src2 == -1) ? (word_t)INT32_MIN
                                                                        : (word_t)((sword_t)src1 / (sword_t)src2));
  INSTPAT("0000001 ????? ????? 101 ????? 01100 11", divu, R,
          R(rd) = ((word_t)src2 == 0) ? (word_t)~0 : (word_t)src1 / (word_t)src2);
  INSTPAT("0000001 ????? ????? 110 ????? 01100 11", rem, R,
          R(rd) = ((sword_t)src2 == 0)                                  ? src1
                  : ((sword_t)src1 == INT32_MIN && (sword_t)src2 == -1) ? 0
                                                                        : (word_t)((sword_t)src1 % (sword_t)src2));
  INSTPAT("0000001 ????? ????? 111 ????? 01100 11", remu, R, R(rd) = ((word_t)src2 == 0) ? src1 : (word_t)src1 % (word_t)src2);

  // Zba Extension
  INSTPAT("0010000 ????? ????? 010 ????? 01100 11", sh1add, R, R(rd) = (src1 << 1) + src2);
  INSTPAT("0010000 ????? ????? 100 ????? 01100 11", sh2add, R, R(rd) = (src1 << 2) + src2);
  INSTPAT("0010000 ????? ????? 110 ????? 01100 11", sh3add, R, R(rd) = (src1 << 3) + src2);

  // Zbb Extension
  INSTPAT("0100000 ????? ????? 111 ????? 01100 11", andn, R, R(rd) = src1 & ~src2);
  INSTPAT("0100000 ????? ????? 110 ????? 01100 11", orn, R, R(rd) = src1 | ~src2);
  INSTPAT("0100000 ????? ????? 100 ????? 01100 11", xnor, R, R(rd) = src1 ^ ~src2);
  INSTPAT("0000101 ????? ????? 110 ????? 01100 11", max, R, R(rd) = ((sword_t)src1 > (sword_t)src2) ? src1 : src2);
  INSTPAT("0000101 ????? ????? 111 ????? 01100 11", maxu, R, R(rd) = ((word_t)src1 > (word_t)src2) ? src1 : src2);
  INSTPAT("0000101 ????? ????? 100 ????? 01100 11", min, R, R(rd) = ((sword_t)src1 < (sword_t)src2) ? src1 : src2);
  INSTPAT("0000101 ????? ????? 101 ????? 01100 11", minu, R, R(rd) = ((word_t)src1 < (word_t)src2) ? src1 : src2);
  INSTPAT("0110000 ????? ????? 001 ????? 01100 11", rol, R, {
    unsigned shamt = src2 & (sizeof(word_t) * 8 - 1);
    R(rd) = (src1 << shamt) | ((word_t)src1 >> ((sizeof(word_t) * 8 - shamt) & (sizeof(word_t) * 8 - 1))); });
  INSTPAT("0110000 ????? ????? 101 ????? 01100 11", ror, R, {
    unsigned shamt = src2 & (sizeof(word_t) * 8 - 1);
    R(rd) = ((word_t)src1 >> shamt) | (src1 << ((sizeof(word_t) * 8 - shamt) & (sizeof(word_t) * 8 - 1))); });
#ifndef CONFIG_RV64
  INSTPAT("0000100 00000 ????? 100 ????? 01100 11", zext.h, R, R(rd) = (word_t)(uint16_t)src1);
#endif

  // Zbs Extension
  INSTPAT("0100100 ????? ????? 001 ????? 01100 11", bclr, R, R(rd) = src1 & ~((word_t)1 << (src2 & (sizeof(word_t) * 8 - 1))));
  INSTPAT("0100100 ????? ????? 101 ????? 01100 11", bext, R, R(rd) = ((word_t)src1 >> (src2 & (sizeof(word_t) * 8 - 1))) & 1);
  INSTPAT("0110100 ????? ????? 001 ????? 01100 11", binv, R, R(rd) = src1 ^ ((word_t)1 << (src2 & (sizeof(word_t) * 8 - 1))));
  INSTPAT("0010100 ????? ????? 001 ????? 01100 11", bset, R, R(rd) = src1 | ((word_t)1 << (src2 & (sizeof(word_t) * 8 - 1))));

  // Zbc Extension (Carry-less Multiplication)
  INSTPAT("0000101 ????? ????? 001 ????? 01100 11", clmul, R, {
    word_t a = src1, b = src2, result = 0;
    for (unsigned i = 0; i < sizeof(word_t) * 8; i++)
      if ((b >> i) & 1) result ^= a << i;
    R(rd) = result; });
  INSTPAT("0000101 ????? ????? 011 ????? 01100 11", clmulh, R, {
    word_t a = src1, b = src2;
    word_t result = 0;
    for (unsigned i = 1; i < sizeof(word_t) * 8; i++)
      if ((b >> i) & 1) result ^= a >> (sizeof(word_t) * 8 - i);
    R(rd) = result; });
  INSTPAT("0000101 ????? ????? 010 ????? 01100 11", clmulr, R, {
    word_t a = src1, b = src2, result = 0;
    for (unsigned i = 0; i < sizeof(word_t) * 8; i++)
      if ((b >> i) & 1) result ^= a >> (sizeof(word_t) * 8 - 1 - i);
    R(rd) = result; });

  // Zicond (Conditional Operations)
  INSTPAT("0000111 ????? ????? 101 ????? 01100 11", czero.eqz, R, R(rd) = (src2 == 0) ? 0 : src1);
  INSTPAT("0000111 ????? ????? 111 ????? 01100 11", czero.nez, R, R(rd) = (src2 != 0) ? 0 : src1);
  INSTPAT_CASE_END(grp_op)

#ifdef CONFIG_RV64
  // RV64I OP-IMM-32 and OP-32 (RV64-only opcode groups; in RV32 these encodings
  // are reserved and must trap illegal-instruction, so the cases are omitted.)
  INSTPAT_CASE(0b00110, grp_opimm32) // OP-IMM-32 (RV64 only)
  INSTPAT("??????? ????? ????? 000 ????? 00110 11", addiw, I, R(rd) = SEXT((uint32_t)src1 + imm, 32));
  INSTPAT("0000000 ????? ????? 001 ????? 00110 11", slliw, I, R(rd) = SEXT((uint32_t)src1 << (imm & 0x1f), 32));
  INSTPAT("0000000 ????? ????? 101 ????? 00110 11", srliw, I, R(rd) = SEXT((uint32_t)src1 >> (imm & 0x1f), 32));
  INSTPAT("0100000 ????? ????? 101 ????? 00110 11", sraiw, I, R(rd) = SEXT((int32_t)src1 >> (imm & 0x1f), 32));
  // Zba Extension (RV64 only)
  INSTPAT("000010? ????? ????? 001 ????? 00110 11", slli.uw, I, R(rd) = (word_t)(uint32_t)src1 << (imm & 0x3f));
  // Zbb Extension (RV64 only)
  INSTPAT("0110000 00000 ????? 001 ????? 00110 11", clzw, I, {
    uint32_t x = (uint32_t)src1; unsigned count = 32;
    for (int i = 31; i >= 0; i--) { if ((x >> i) & 1) { count = 31 - i; break; } }
    R(rd) = count; });
  INSTPAT("0110000 00001 ????? 001 ????? 00110 11", ctzw, I, {
    uint32_t x = (uint32_t)src1; unsigned count = 32;
    for (unsigned i = 0; i < 32; i++) { if ((x >> i) & 1) { count = i; break; } }
    R(rd) = count; });
  INSTPAT("0110000 00010 ????? 001 ????? 00110 11", cpopw, I, {
    uint32_t x = (uint32_t)src1; unsigned count = 0;
    for (unsigned i = 0; i < 32; i++) { if ((x >> i) & 1) count++; }
    R(rd) = count; });
  INSTPAT("0110000 ????? ????? 101 ????? 00110 11", roriw, I, {
    uint32_t x = (uint32_t)src1; unsigned shamt = imm & 0x1f;
    R(rd) = SEXT((x >> shamt) | (x << ((32 - shamt) & 31)), 32); });
  INSTPAT_CASE_END(grp_opimm32)

  INSTPAT_CASE(0b01110, grp_op32) // OP-32 + RV64M (RV64 only)
  INSTPAT("0000000 ????? ????? 000 ????? 01110 11", addw, R, R(rd) = SEXT((int32_t)src1 + (int32_t)src2, 32));
  INSTPAT("0100000 ????? ????? 000 ????? 01110 11", subw, R, R(rd) = SEXT((int32_t)src1 - (int32_t)src2, 32));
  INSTPAT("0000000 ????? ????? 001 ????? 01110 11", sllw, R, R(rd) = SEXT((uint32_t)src1 << ((uint32_t)src2), 32));
  INSTPAT("0000000 ????? ????? 101 ????? 01110 11", srlw, R, R(rd) = SEXT((uint32_t)src1 >> ((uint32_t)src2), 32));
  INSTPAT("0100000 ????? ????? 101 ????? 01110 11", sraw, R, R(rd) = SEXT((int32_t)src1 >> ((int32_t)src2), 32));
  // RV64M Extension
  INSTPAT("0000001 ????? ????? 000 ????? 01110 11", mulw, R, R(rd) = SEXT((int32_t)src1 * (int32_t)src2, 32));
  INSTPAT("0000001 ????? ????? 100 ????? 01110 11", divw, R, R(rd) = SEXT((int32_t)src1 / (int32_t)src2, 32));
  INSTPAT("0000001 ????? ????? 101 ????? 01110 11", divuw, R, R(rd) = SEXT((uint32_t)src1 / (uint32_t)src2, 32));
  INSTPAT("0000001 ????? ????? 110 ????? 01110 11", remw, R, R(rd) = SEXT((int32_t)src1 % (int32_t)src2, 32));
  INSTPAT("0000001 ????? ????? 111 ????? 01110 11", remuw, R, R(rd) = SEXT((uint32_t)src1 % (uint32_t)src2, 32));
  // Zba Extension (RV64 only)
  INSTPAT("0010000 ????? ????? 010 ????? 01110 11", sh1add.uw, R, R(rd) = ((word_t)(uint32_t)src1 << 1) + src2);
  INSTPAT("0010000 ????? ????? 100 ????? 01110 11", sh2add.uw, R, R(rd) = ((word_t)(uint32_t)src1 << 2) + src2);
  INSTPAT("0010000 ????? ????? 110 ????? 01110 11", sh3add.uw, R, R(rd) = ((word_t)(uint32_t)src1 << 3) + src2);
  INSTPAT("0000100 ????? ????? 000 ????? 01110 11", add.uw, R, R(rd) = (word_t)(uint32_t)src1 + src2);
  // Zbb Extension (RV64 only)
  INSTPAT("0000100 00000 ????? 100 ????? 01110 11", zext.h, R, R(rd) = (word_t)(uint16_t)src1);
  INSTPAT("0110000 ????? ????? 001 ????? 01110 11", rolw, R, {
    uint32_t x = (uint32_t)src1; unsigned shamt = src2 & 31;
    R(rd) = SEXT((x << shamt) | (x >> ((32 - shamt) & 31)), 32); });
  INSTPAT("0110000 ????? ????? 101 ????? 01110 11", rorw, R, {
    uint32_t x = (uint32_t)src1; unsigned shamt = src2 & 31;
    R(rd) = SEXT((x >> shamt) | (x << ((32 - shamt) & 31)), 32); });
  INSTPAT_CASE_END(grp_op32)
#endif // CONFIG_RV64

  INSTPAT_CASE(0b00011, grp_miscmem)                                   // MISC-MEM (fence, fence.i, Zicbom, fence.tso, pause)
  INSTPAT("0000000 10000 00000 000 00000 00011 11", pause, N, {});     // hint instruction (include in fence)
  INSTPAT("1000001 10011 00000 000 00000 00011 11", fence_tso, N, {}); // fence.tso: inst[6:2]=0b00011, same MISC-MEM group
  INSTPAT("??????? ????? ????? 000 ????? 00011 11", fence, N, {});
  INSTPAT("??????? ????? ????? 001 ????? 00011 11", fence_i, I, icache_flush());
  INSTPAT("0000000 00000 ????? 010 00000 00011 11", cbo.inval, N, {});
  INSTPAT("0000000 00001 ????? 010 00000 00011 11", cbo.clean, N, {});
  INSTPAT("0000000 00010 ????? 010 00000 00011 11", cbo.flush, N, {});
  INSTPAT_CASE_END(grp_miscmem)

  INSTPAT_CASE(0b11100, grp_system) // SYSTEM (ecall, ebreak, sfence.vma, mret, sret, wfi, CSRs)
  INSTPAT("0000000 00000 00000 000 00000 11100 11", ecall, N,
          s->dnpc = isa_raise_intr(
              ((cpu.priv == PRV_U) ? MCA_ENV_CAL_UMO : ((cpu.priv == PRV_S) ? MCA_ENV_CAL_SMO : MCA_ENV_CAL_MMO)),
              s->pc));
#if defined(CONFIG_DEBUG)
  INSTPAT("0000000 00001 00000 000 00000 11100 11", ebreak, N, {
    extern int sig_is_enabled(void);
    if (sig_is_enabled())
    {
      s->dnpc = isa_raise_intr(MCA_BREAK_POINT, s->pc);
    }
    else
    {
      NEMUTRAP(s->pc, R(10));
    }
  }); // R(10) is $a0
#else
  INSTPAT("0000000 00001 00000 000 00000 11100 11", ebreak, N, { s->dnpc = isa_raise_intr(MCA_BREAK_POINT, s->pc); });
#endif
  INSTPAT("0001001 ????? ????? 000 00000 11100 11", sfence.vma, N, {
    csr_t ms = {.val = CSR(CSR_MSTATUS)};
    if (cpu.priv == PRV_U || (cpu.priv == PRV_S && ms.mstatus.tvm))
    {
      s->dnpc = isa_raise_intr(MCA_ILLEGAL_INS, s->pc);
      difftest_skip_ref();
    }
    else
    {
      soft_tlb_flush();
    }
  });
  // RV32/RV64 Zicsr Extension
  INSTPAT("??????? ????? ????? 001 ????? 11100 11", csrrw, I, { if (csr_valid(s, imm, true)) {R(rd) = CSR(imm); CSRW(imm, src1); } });
  INSTPAT("??????? ????? ????? 010 ????? 11100 11", csrrs, I, { if (csr_valid(s, imm, rs1 != 0)) {R(rd) = CSR(imm); if (rs1 != 0) { CSRW(imm, CSR(imm) | src1);}; } });
  INSTPAT("??????? ????? ????? 011 ????? 11100 11", csrrc, I, { if (csr_valid(s, imm, rs1 != 0)) {R(rd) = CSR(imm); if (rs1 != 0) { CSRW(imm, CSR(imm) & ~src1);}; } });
  INSTPAT("??????? ????? ????? 101 ????? 11100 11", csrrwi, I_I, { if (csr_valid(s, imm, true)) { R(rd) = CSR(imm); CSRW(imm, src1);} });
  INSTPAT("??????? ????? ????? 110 ????? 11100 11", csrrsi, I_I, { if (csr_valid(s, imm, rs1 != 0)) { R(rd) = CSR(imm); if (rs1 != 0) { CSRW(imm, CSR(imm) | src1); };} });
  INSTPAT("??????? ????? ????? 111 ????? 11100 11", csrrci, I_I, { if (csr_valid(s, imm, rs1 != 0)) { R(rd) = CSR(imm); if (rs1 != 0) { CSRW(imm, CSR(imm) & ~src1); };} });
  // Trap-Return Instructions
  INSTPAT("0011000 00010 00000 000 00000 11100 11", mret, N, s->dnpc = CSR(CSR_MEPC);
          csr_t reg = {.val = CSR(CSR_MSTATUS)};
          cpu.last_inst_priv = cpu.priv;
          cpu.priv = reg.mstatus.mpp;
          if (cpu.priv != PRV_M) reg.mstatus.mprv = 0;
          reg.mstatus.mie = reg.mstatus.mpie;
          reg.mstatus.mpie = 1;
          reg.mstatus.mpp = PRV_U;
          CSR(CSR_MSTATUS) = reg.val;
          soft_tlb_flush(););
  INSTPAT("0001000 00010 00000 000 00000 11100 11", sret, N, s->dnpc = CSR(CSR_SEPC);
          csr_t reg = {.val = CSR(CSR_MSTATUS)};
          cpu.last_inst_priv = cpu.priv;
          cpu.priv = reg.mstatus.spp;
          reg.mstatus.sie = reg.mstatus.spie;
          reg.mstatus.spie = 1;
          reg.mstatus.spp = 0;
          /* sret returning to priv != M clears MPRV (spec). */
          if (cpu.priv != PRV_M) reg.mstatus.mprv = 0;
          CSR(CSR_MSTATUS) = reg.val;
          /* SSTATUS view will be re-derived by post-instruction code. */
          soft_tlb_flush(););
  // Interrupt-Management Instructions
  INSTPAT("0001000 00101 00000 000 00000 11100 11", wfi, N, {
#if !defined(CONFIG_TARGET_SHARE)
    // WFI acceleration: if no interrupt pending, advance time to mtimecmp
    word_t pending = cpu.sr[CSR_MIP] & cpu.sr[CSR_MIE];
    if (pending == 0)
      clint_wfi_advance();
#endif
    difftest_skip_ref();
  });
  // Zimop: May-Be-Operations. Architecturally write 0 to rd; semantics
  // reserved for future repurposing. Currently decode as NOP + rd<-0.
  // MOP.r.n  : 1-00--0111-- sssss 100 ddddd 1110011  (32 MOPs)
  INSTPAT("1?00??0111?? ????? 100 ????? 11100 11", mop.r, I, R(rd) = 0);
  // MOP.rr.n : 1-00--1 rs2 rs1 100 rd 1110011  (8 MOPs)
  INSTPAT("1?00??1 ????? ????? 100 ????? 11100 11", mop.rr, R, R(rd) = 0);
  INSTPAT_CASE_END(grp_system)

  INSTPAT_CASE(0b01011, grp_amo) // AMO (RV32A + RV64A)
  /* AMO_PRECHECK: AMOs must report store/AMO-access-fault (cause=7) on ANY
   * PMP violation (load OR store side), per RISC-V priv spec 3.7.  Without
   * this precheck, NEMU's Mr-then-Mw sequence would emit load-fault (5)
   * when only the R bit is clear, diverging from sail/RTL. */
  extern bool pmp_check(paddr_t addr, int size, uint32_t priv, bool op_r, bool op_w, bool op_x);
  extern uint32_t pmp_effective_priv_ls(void);
  extern jmp_buf exec_jmp_buf;
  extern int cause;
  extern word_t g_vaddr;
  extern word_t pmp_last_fault_addr;
#define AMO_PRECHECK(addr, len)                                    \
  do                                                               \
  {                                                                \
    if (pmp_check((paddr_t)(addr), (len), pmp_effective_priv_ls(), \
                  true, true, false))                              \
    {                                                              \
      g_vaddr = pmp_last_fault_addr;                               \
      cause = MCA_STO_ACC_FAU;                                     \
      nemu_longjmp(exec_jmp_buf, 24);                              \
    }                                                              \
  } while (0)
  // RV32A Extension
  INSTPAT("00010?? 00000 ????? 010 ????? 01011 11", lr.w, R, { R(rd) = SEXT(Mr(src1, 4), 32); cpu.reservation = get_paddr(src1, 4); });
  INSTPAT("00011?? ????? ????? 010 ????? 01011 11", sc.w, R, {
    if (cpu.reservation == get_paddr(src1, 4)) { R(rd) = 0; Mw(src1, 4, src2); } else { R(rd) = 1; }; cpu.reservation = 0; });
  INSTPAT("00001?? ????? ????? 010 ????? 01011 11", amoswap.w, R, {AMO_PRECHECK(src1, 4); sword_t tmp = Mr(src1, 4); Mw(src1, 4, src2); R(rd) = SEXT(tmp, 32); });
  INSTPAT("00000?? ????? ????? 010 ????? 01011 11", amoadd.w, R, {AMO_PRECHECK(src1, 4); sword_t  tmp = Mr(src1, 4); Mw(src1, 4, src2 + tmp); R(rd) = SEXT(tmp, 32); });
  INSTPAT("00100?? ????? ????? 010 ????? 01011 11", amoxor.w, R, { AMO_PRECHECK(src1, 4); sword_t tmp = Mr(src1, 4); Mw(src1, 4, src2 ^ tmp); R(rd) = SEXT(tmp, 32); });
  INSTPAT("01100?? ????? ????? 010 ????? 01011 11", amoand.w, R, { AMO_PRECHECK(src1, 4); sword_t tmp = Mr(src1, 4); Mw(src1, 4, src2 & tmp); R(rd) = SEXT(tmp, 32); });
  INSTPAT("01000?? ????? ????? 010 ????? 01011 11", amoor.w, R, { AMO_PRECHECK(src1, 4); sword_t  tmp = Mr(src1, 4); Mw(src1, 4, src2 | tmp); R(rd) = SEXT(tmp, 32); });
  INSTPAT("10000?? ????? ????? 010 ????? 01011 11", amomin.w, R, {AMO_PRECHECK(src1, 4); sword_t  tmp = Mr(src1, 4); Mw(src1, 4, (tmp < (sword_t)src2) ? tmp : src2);R(rd) = SEXT(tmp, 32); });
  INSTPAT("10100?? ????? ????? 010 ????? 01011 11", amomax.w, R, {AMO_PRECHECK(src1, 4); sword_t  tmp = Mr(src1, 4); Mw(src1, 4, (tmp > (sword_t)src2) ? tmp : src2);R(rd) = SEXT(tmp, 32); });
  INSTPAT("11000?? ????? ????? 010 ????? 01011 11", amominu.w, R, {AMO_PRECHECK(src1, 4); word_t tmp = Mr(src1, 4); Mw(src1, 4, (tmp < (uint32_t)src2) ? tmp : src2);R(rd) = SEXT(tmp, 32); });
  INSTPAT("11100?? ????? ????? 010 ????? 01011 11", amomaxu.w, R, {AMO_PRECHECK(src1, 4); word_t tmp = Mr(src1, 4); Mw(src1, 4, (tmp > (uint32_t)src2) ? tmp : src2);R(rd) = SEXT(tmp, 32); });
  // RV64A Extension
  INSTPAT("00010?? 00000 ????? 011 ????? 01011 11", lr.d, R, {
    R(rd) = Mr(src1, 8); cpu.reservation = get_paddr(src1, 8); });
  INSTPAT("00011?? ????? ????? 011 ????? 01011 11", sc.d, R, {
    if (cpu.reservation == get_paddr(src1, 8)) { R(rd) = 0; Mw(src1, 8, src2); } else { R(rd) = 1; }; cpu.reservation = 0; });
  INSTPAT("00001?? ????? ????? 011 ????? 01011 11", amoswap.d, R, {AMO_PRECHECK(src1, 8); sword_t tmp = Mr(src1, 8);Mw(src1, 8, src2);R(rd) = tmp; });
  INSTPAT("00000?? ????? ????? 011 ????? 01011 11", amoadd.d, R, {AMO_PRECHECK(src1, 8); sword_t tmp = Mr(src1, 8);Mw(src1, 8, src2 + tmp);R(rd) = tmp; });
  INSTPAT("00100?? ????? ????? 011 ????? 01011 11", amoxor.d, R, {AMO_PRECHECK(src1, 8); sword_t tmp = Mr(src1, 8);Mw(src1, 8, src2 ^ tmp);R(rd) = tmp; });
  INSTPAT("01100?? ????? ????? 011 ????? 01011 11", amoand.d, R, {AMO_PRECHECK(src1, 8); sword_t tmp = Mr(src1, 8);Mw(src1, 8, src2 & tmp);R(rd) = tmp; });
  INSTPAT("01000?? ????? ????? 011 ????? 01011 11", amoor.d, R, {AMO_PRECHECK(src1, 8); sword_t tmp = Mr(src1, 8);Mw(src1, 8, src2 | tmp);R(rd) = tmp; });
  INSTPAT("10000?? ????? ????? 011 ????? 01011 11", amomin.d, R, {AMO_PRECHECK(src1, 8); sword_t tmp = Mr(src1, 8);Mw(src1, 8, (tmp < src2) ? tmp : src2);R(rd) = tmp; });
  INSTPAT("10100?? ????? ????? 011 ????? 01011 11", amomax.d, R, {AMO_PRECHECK(src1, 8); sword_t tmp = Mr(src1, 8);Mw(src1, 8, (tmp > src2) ? tmp : src2);R(rd) = tmp; });
  INSTPAT("11000?? ????? ????? 011 ????? 01011 11", amominu.d, R, {AMO_PRECHECK(src1, 8); sword_t tmp = Mr(src1, 8);Mw(src1, 8, (tmp < src2) ? src2 : tmp);R(rd) = tmp; });
  INSTPAT("11100?? ????? ????? 011 ????? 01011 11", amomaxu.d, R, {AMO_PRECHECK(src1, 8); AMO_PRECHECK(src1, 8); sword_t tmp = Mr(src1, 8);Mw(src1, 8, (tmp > src2) ? src2 : tmp);R(rd) = tmp; });
  INSTPAT_CASE_END(grp_amo)

  INSTPAT_DEFAULT()
  INSTPAT("??????? ????? ????? ??? ????? ????? ??", inv, N, {
    if (CSR(CSR_MTVEC))
    {
      s->dnpc = isa_raise_intr(MCA_ILLEGAL_INS, s->pc);
    }
    else
    {
      INV(s->pc);
    } });
  INSTPAT_SWITCH_END();

  // mstatus write mask: clear non-writable bits.
  // SD (bit 31/63) is read-only (computed below); VS (bits 10:9) hardwired 0 (no V ext).
  // RV64: SXL[35:34] and UXL[33:32] are WARL fields that hold XLEN==2 and are
  // enforced below regardless of writes.
#ifdef CONFIG_RV64
#define MSTATUS_WMASK 0x000000FF007FF9EAULL
#else
#define MSTATUS_WMASK 0x007FF9EA
#endif
  CSR(CSR_MSTATUS) = CSR(CSR_MSTATUS) & MSTATUS_WMASK;
  CSR(CSR_MISA) = CSR_MISA_VALUE;
  // medeleg is WARL: only delegable synchronous exceptions are writable,
  // matching the Spike reference for this extension set (RV32IMAC+S, Zicntr,
  // no Zicfiss/Zicfilp/H): bits 1-9, 12/13/15 (page faults), 19 (hw error).
  // Hardwired 0: bit 0 (misaligned fetch; C ext), bit 11 (ecall-M, per spec),
  // bit 18 (software check; needs Zicfiss/Zicfilp), reserved bits.
  CSR(CSR_MEDELEG) &= 0x8b3fe;
  CSR(CSR_MIDELEG) &= 0x222;
  // sstatus/sie are architecturally views of mstatus/mie (not separate regs).
  // Propagate direct writes back to mstatus/mie at any privilege level.
  // sstatus read mask: includes SD (computed), excludes VS.
#ifdef CONFIG_RV64
#define SSTATUS_RMASK 0x80000003000DE162ULL
#else
#define SSTATUS_RMASK 0x800de162
#endif
#define SIE_RMASK 0x222
#define SIP_RMASK 0x222
#define SIP_WMASK 0x2
  /* SSTATUS/SIE are architectural views of MSTATUS/MIE.  If the last CSR
   * write targeted SSTATUS/SIE, propagate the (masked) value into the real
   * MSTATUS/MIE.  Otherwise, SSTATUS/SIE are always re-derived below from
   * MSTATUS/MIE, so there is nothing else to sync. */
  if (cpu.last_csr_wr == CSR_SSTATUS)
  {
    word_t ms_bits = CSR(CSR_SSTATUS) & SSTATUS_RMASK;
    CSR(CSR_MSTATUS) = (CSR(CSR_MSTATUS) & ~SSTATUS_RMASK) | ms_bits;
    CSR(CSR_MSTATUS) &= MSTATUS_WMASK;
  }
  if (cpu.last_csr_wr == CSR_SIE)
  {
    word_t mie_bits = CSR(CSR_SIE) & SIE_RMASK;
    CSR(CSR_MIE) = (CSR(CSR_MIE) & ~SIE_RMASK) | mie_bits;
  }
  if (cpu.last_csr_wr == CSR_SIP)
  {
    word_t mip_bits = CSR(CSR_SIP) & SIP_WMASK;
    CSR(CSR_MIP) = (CSR(CSR_MIP) & ~SIP_WMASK) | mip_bits;
  }
  cpu.last_csr_wr = 0;
#ifdef CONFIG_RV64
  /* SXL/UXL are WARL: pin to XLEN=64 (encoding 2) after all MSTATUS writes.
   * Must come after SSTATUS propagation which applies MSTATUS_WMASK again. */
  CSR(CSR_MSTATUS) = (CSR(CSR_MSTATUS) & ~0xF00000000ULL) | 0xA00000000ULL;
#endif
  // Compute SD (read-only): set when FS, VS, or XS is Dirty (== 3)
  {
    word_t fs = (CSR(CSR_MSTATUS) >> 13) & 3;
    word_t vs = (CSR(CSR_MSTATUS) >> 9) & 3;
    word_t xs = (CSR(CSR_MSTATUS) >> 15) & 3;
#ifdef CONFIG_RV64
    if (fs == 3 || vs == 3 || xs == 3)
      CSR(CSR_MSTATUS) |= (1ULL << 63);
#else
    if (fs == 3 || vs == 3 || xs == 3)
      CSR(CSR_MSTATUS) |= 0x80000000u;
#endif
  }
  // Derive sstatus/sie from mstatus/mie
#ifdef CONFIG_RV64
  CSR(CSR_SSTATUS) = CSR(CSR_MSTATUS) & SSTATUS_RMASK;
  CSR(CSR_SIE) = CSR(CSR_MIE) & SIE_RMASK;
#else
  CSR(CSR_SSTATUS) = CSR(CSR_MSTATUS) & SSTATUS_RMASK;
  CSR(CSR_SIE) = CSR(CSR_MIE) & SIE_RMASK;
#endif

  uint64_t inst_advance = 1;
  CSR(CSR_CYCLE_) = CSR(CSR_CYCLE_) + inst_advance;
  CSR(CSR_MCYCLE) = CSR(CSR_MCYCLE) + inst_advance;
  CSR(CSR_INSTRET) = CSR(CSR_INSTRET) + inst_advance;
  CSR(CSR_MINSTRET) = CSR(CSR_INSTRET);
  /* See RV32 sibling for the deadlock-safety rationale of this gate. */
#define TIMER_TICK_INTERVAL 1024u
  if ((g_nr_guest_inst & (TIMER_TICK_INTERVAL - 1)) == 0)
  {
#if defined(CONFIG_TIMER_CYCLE)
    uint64_t ticks = (g_nr_guest_inst + inst_advance) / 100;
#else
    uint64_t ticks = get_time() * 10;
#endif
    CSR(CSR_TIME) = (word_t)ticks;
#ifndef CONFIG_RV64
    CSR(CSR_TIMEH) = (uint32_t)(ticks >> 32);
#endif
#if !defined(CONFIG_TARGET_SHARE)
    clint_update_mip();
#endif
  }
  // sip is a restricted view of mip per the privileged spec; this mirror
  // must run unconditionally (also under CONFIG_TARGET_SHARE difftest builds)
  // so that M-mode writes to mip.STIP/SSIP/SEIP become visible via sip.
  CSR(CSR_SIP) = CSR(CSR_MIP) & SIP_RMASK;
#undef TIMER_TICK_INTERVAL

  R(0) = 0; // reset $zero to 0

#if !defined(CONFIG_TARGET_SHARE)
  ftrace_add(s->pc, s->dnpc, s->isa.inst);
#endif
  s->pc = s->dnpc;
  return 0;
}

jmp_buf exec_jmp_buf;
int cause;

int isa_exec_once(Decode *s)
{
  // instruction fetch (skipped on decode-cache hit)
  int jmp_value = nemu_setjmp(exec_jmp_buf);
  if (jmp_value)
  {
    s->pc = isa_raise_intr(cause, s->pc);
    s->isa.inst = 0x13; // addi x0, x0, 0; a.k.a. NOP
    return 0;
  }
  icache_entry_t *e = icache_slot(s->pc);
  if (icache_hit(e, s->pc))
  {
    s->isa.inst = e->inst;
    s->snpc = s->pc + e->ilen;
  }
  else
  {
    s->isa.inst = inst_fetch(&s->snpc, 4); // advances snpc to pc+4
  }
  cpu.inst = s->isa.inst;

  // instruction decode and execute
  jmp_value = nemu_setjmp(exec_jmp_buf);
  if (jmp_value)
  {
    s->pc = isa_raise_intr(cause, s->pc);
    s->isa.inst = 0x13; // addi x0, x0, 0; a.k.a. NOP
    return 0;
  }
  vaddr_t fill_pc = s->pc; // decode_exec will clobber s->pc <- dnpc
  int ret = decode_exec(s);
  if (!icache_hit(e, fill_pc))
  {
    icache_fill(e, fill_pc, s->isa.inst, (uint16_t)(s->snpc - fill_pc));
  }
  return ret;
}

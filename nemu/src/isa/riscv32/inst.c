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
#include <elf.h>

#define R(i) gpr(i)
#define CSR(i) sr(i)
#define Mr vaddr_read
#define Mw vaddr_write
#define MAX_FTRACE_SIZE 1024
#define MAX_ELF_SIZE 32 * 1024

typedef struct Ftrace
{
  word_t pc;
  word_t npc;
  word_t depth;
  bool ret;
} Ftrace;

Ftrace ftracebuf[MAX_FTRACE_SIZE];
word_t ftracehead = 0;
word_t ftracedepth = 0;
char elfbuf[MAX_ELF_SIZE];

typedef MUXDEF(CONFIG_ISA64, Elf64_Ehdr, Elf32_Ehdr) Elf_Ehdr;
typedef MUXDEF(CONFIG_ISA64, Elf64_Shdr, Elf32_Shdr) Elf_Shdr;
typedef MUXDEF(CONFIG_ISA64, Elf64_Sym, Elf32_Sym) Elf_Sym;
Elf_Ehdr elf_ehdr;
Elf_Shdr *elfshdr_symtab = NULL, *elfshdr_strtab = NULL;

enum
{
  TYPE_R,
  TYPE_I,
  TYPE_I_I,
  TYPE_S,
  TYPE_B,
  TYPE_U,
  TYPE_J,
  TYPE_N,
};

#define src1R()     \
  do                \
  {                 \
    *src1 = R(rs1); \
  } while (0)
#define src2R()     \
  do                \
  {                 \
    *src2 = R(rs2); \
  } while (0)
#define immI()                        \
  do                                  \
  {                                   \
    *imm = SEXT(BITS(i, 31, 20), 12); \
  } while (0)
#define immU()                              \
  do                                        \
  {                                         \
    *imm = SEXT(BITS(i, 31, 12), 20) << 12; \
  } while (0)
#define immS()                                               \
  do                                                         \
  {                                                          \
    *imm = (SEXT(BITS(i, 31, 25), 7) << 5) | BITS(i, 11, 7); \
  } while (0)
#define immB()                                 \
  do                                           \
  {                                            \
    *imm = ((SEXT(BITS(i, 31, 31), 1) << 12) | \
            (BITS(i, 7, 7) << 11) |            \
            (BITS(i, 30, 25) << 5) |           \
            (BITS(i, 11, 8) << 1)) &           \
           ~1;                                 \
  } while (0)
#define immJ()                                 \
  do                                           \
  {                                            \
    *imm = ((SEXT(BITS(i, 31, 31), 1) << 20) | \
            (BITS(i, 19, 12) << 12) |          \
            (BITS(i, 20, 20) << 11) |          \
            (BITS(i, 30, 25) << 5) |           \
            (BITS(i, 24, 21) << 1)) &          \
           ~1;                                 \
  } while (0)

uint64_t get_mtimecmp();
word_t get_paddr(vaddr_t addr, int len);

bool csr_valid(Decode *s, uint16_t csr)
{
  csr = csr & 0xfff;
  if (likely(
          csr == CSR_SSTATUS ||
          csr == CSR_SIE ||
          csr == CSR_STVEC ||

          csr == CSR_SCOUNTEREN ||

          csr == CSR_SSCRATCH ||
          csr == CSR_SEPC ||
          csr == CSR_SCAUSE ||
          csr == CSR_STVAL ||
          csr == CSR_SIP ||
          csr == CSR_SATP ||

          csr == CSR_MSTATUS ||
          csr == CSR_MISA ||
          csr == CSR_MEDELEG ||
          csr == CSR_MIDELEG ||
          csr == CSR_MIE ||
          csr == CSR_MTVEC ||

          csr == CSR_MSTATUSH ||

          csr == CSR_MSCRATCH ||
          csr == CSR_MEPC ||
          csr == CSR_MCAUSE ||
          csr == CSR_MTVAL ||
          csr == CSR_MIP ||

          csr == CSR_MCYCLE ||
          csr == CSR_TIME ||
          csr == CSR_TIMEH ||

          csr == CSR_MVENDORID ||
          csr == CSR_MARCHID ||
          csr == CSR_IMPID ||
          csr == CSR_MHARTID))
  {
    if (
        csr == CSR_MISA ||
        csr == CSR_TIME ||
        csr == CSR_TIMEH ||
        csr == CSR_MVENDORID ||
        csr == CSR_MARCHID)
    {
      difftest_skip_ref();
    }
    return true;
  }

  s->dnpc = isa_raise_intr(MCA_ILL_INS, s->pc);
  difftest_skip_ref();
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
    |  imm[11:0]              |   rs1   |funct3|  rd    | opcode | I-type
    |  imm[11:5]    |   rs2   |   rs1   |funct3|imm[4:0]| opcode | S-type
    |  imm[12|10:5] |   rs2   |   rs1|funct3|imm[4:1|11]| opcode | B-type
    |  imm[31:12]                              |   rd   | opcode | U-type
    |  imm[20|10:1|11|19:12]                   |   rd   | opcode | J-type
 */
static int decode_exec(Decode *s)
{
  s->dnpc = s->snpc;

#define INSTPAT_INST(s) ((s)->isa.inst)
#define INSTPAT_MATCH(s, name, type, ... /* execute body */)               \
  {                                                                        \
    int rd = 0, rs1 = 0;                                                   \
    word_t src1 = 0, src2 = 0, imm = 0;                                    \
    decode_operand(s, &rd, &rs1, &src1, &src2, &imm, concat(TYPE_, type)); \
    __VA_ARGS__;                                                           \
  }

  INSTPAT_START();
  //      |31      24    19    14  11    6      0|
  INSTPAT("??????? ????? ????? ??? ????? 01101 11", lui, U, R(rd) = imm);
  INSTPAT("??????? ????? ????? ??? ????? 00101 11", auipc, U, R(rd) = s->pc + imm);
  INSTPAT("??????? ????? ????? ??? ????? 11011 11", jal, J, R(rd) = s->pc + 4; s->dnpc = (s->pc + imm) & ~1);
  INSTPAT("??????? ????? ????? 000 ????? 11001 11", jalr, I, R(rd) = s->pc + 4; s->dnpc = (src1 + imm) & ~1);

  INSTPAT("??????? ????? ????? 000 ????? 11000 11", beq, B, if (src1 == src2) s->dnpc = s->pc + imm);
  INSTPAT("??????? ????? ????? 001 ????? 11000 11", bne, B, if (src1 != src2) s->dnpc = s->pc + imm);
  INSTPAT("??????? ????? ????? 100 ????? 11000 11", blt, B, if ((sword_t)src1 < (sword_t)src2) s->dnpc = s->pc + imm);
  INSTPAT("??????? ????? ????? 101 ????? 11000 11", bge, B, if ((sword_t)src1 >= (sword_t)src2) s->dnpc = s->pc + imm);
  INSTPAT("??????? ????? ????? 110 ????? 11000 11", bltu, B, if ((word_t)src1 < (word_t)src2) s->dnpc = s->pc + imm);
  INSTPAT("??????? ????? ????? 111 ????? 11000 11", bgeu, B, if ((word_t)src1 >= (word_t)src2) s->dnpc = s->pc + imm);

  INSTPAT("??????? ????? ????? 000 ????? 00000 11", lb, I, R(rd) = SEXT(Mr(src1 + imm, 1), 8));
  INSTPAT("??????? ????? ????? 001 ????? 00000 11", lh, I, R(rd) = SEXT(Mr(src1 + imm, 2), 16));
  INSTPAT("??????? ????? ????? 010 ????? 00000 11", lw, I, R(rd) = SEXT(Mr(src1 + imm, 4), 32));

  INSTPAT("??????? ????? ????? 100 ????? 00000 11", lbu, I, { R(rd) = Mr(src1 + imm, 1); });
  INSTPAT("??????? ????? ????? 101 ????? 00000 11", lhu, I, { R(rd) = Mr(src1 + imm, 2); });

  INSTPAT("??????? ????? ????? 000 ????? 01000 11", sb, S, Mw(src1 + imm, 1, src2));
  INSTPAT("??????? ????? ????? 001 ????? 01000 11", sh, S, Mw(src1 + imm, 2, src2));
  INSTPAT("??????? ????? ????? 010 ????? 01000 11", sw, S, Mw(src1 + imm, 4, src2));

  INSTPAT("??????? ????? ????? 000 ????? 00100 11", addi, I, R(rd) = (sword_t)src1 + imm);
  INSTPAT("??????? ????? ????? 010 ????? 00100 11", slti, I, R(rd) = ((sword_t)src1 < (sword_t)imm) ? 1 : 0);
  INSTPAT("??????? ????? ????? 011 ????? 00100 11", sltiu, I, R(rd) = ((word_t)src1 < (word_t)imm) ? 1 : 0);
  INSTPAT("??????? ????? ????? 100 ????? 00100 11", xori, I, R(rd) = src1 ^ imm);
  INSTPAT("??????? ????? ????? 110 ????? 00100 11", ori, I, R(rd) = src1 | imm);
  INSTPAT("??????? ????? ????? 111 ????? 00100 11", andi, I, R(rd) = src1 & imm);

  INSTPAT("0000000 ????? ????? 001 ????? 00100 11", slli, I, R(rd) = src1 << (imm & 0x1f));
  INSTPAT("0000000 ????? ????? 101 ????? 00100 11", srli, I, R(rd) = ((word_t)src1) >> (imm & 0x1f));
  INSTPAT("0100000 ????? ????? 101 ????? 00100 11", srai, I, R(rd) = ((sword_t)src1) >> (imm & 0x1f));

  INSTPAT("0000000 ????? ????? 000 ????? 01100 11", add, R, R(rd) = src1 + src2);
  INSTPAT("0100000 ????? ????? 000 ????? 01100 11", sub, R, R(rd) = src1 - src2);
  INSTPAT("0000000 ????? ????? 001 ????? 01100 11", sll, R, R(rd) = src1 << (src2 & 0x1f));
  INSTPAT("0000000 ????? ????? 010 ????? 01100 11", slt, R, R(rd) = (sword_t)src1 < (sword_t)src2);
  INSTPAT("0000000 ????? ????? 011 ????? 01100 11", sltu, R, R(rd) = ((word_t)src1 < (word_t)src2) ? 1 : 0);
  INSTPAT("0000000 ????? ????? 100 ????? 01100 11", xor, R, R(rd) = src1 ^ src2);
  INSTPAT("0000000 ????? ????? 101 ????? 01100 11", srl, R, R(rd) = src1 >> (src2 & 0x1f));
  INSTPAT("0100000 ????? ????? 101 ????? 01100 11", sra, R, R(rd) = SEXT(src1, sizeof(word_t) * 8) >> (src2 & 0x1f));
  INSTPAT("0000000 ????? ????? 110 ????? 01100 11", or, R, R(rd) = src1 | src2);
  INSTPAT("0000000 ????? ????? 111 ????? 01100 11", and, R, R(rd) = src1 & src2);

  INSTPAT("0000??? ????? 00000 000 00000 00011 11", fence, N, {});
  INSTPAT("1000001 10011 00000 000 00000 00111 11", fence_tso, N, {});
  INSTPAT("0000000 10000 00000 000 00000 00011 11", pause, N, {});
  INSTPAT("0000000 00000 00000 000 00000 11100 11", ecall, N,
          s->dnpc = isa_raise_intr(
              ((cpu.priv == PRV_U) ? MCA_ENV_CAL_UMO : ((cpu.priv == PRV_S) ? MCA_ENV_CAL_SMO : MCA_ENV_CAL_MMO)),
              s->pc));
#if defined(CONFIG_ROM_DTB)
  INSTPAT("0000000 00001 00000 000 00000 11100 11", ebreak, N, { s->dnpc = isa_raise_intr(MCA_BRE, s->pc); });
#else
  INSTPAT("0000000 00001 00000 000 00000 11100 11", ebreak, N, NEMUTRAP(s->pc, R(10))); // R(10) is $a0
#endif

  // RV64I Base Instruction Set
  INSTPAT("??????? ????? ????? 110 ????? 00000 11", lwu, I, R(rd) = Mr(src1 + imm, 4));
  INSTPAT("??????? ????? ????? 011 ????? 00000 11", ld, I, R(rd) = Mr(src1 + imm, 8));
  INSTPAT("??????? ????? ????? 011 ????? 01000 11", sd, S, Mw(src1 + imm, 8, src2));

  INSTPAT("000000? ????? ????? 001 ????? 00100 11", slli, I, R(rd) = src1 << (imm & 0x3f));
  INSTPAT("000000? ????? ????? 101 ????? 00100 11", srli, I, R(rd) = (word_t)src1 >> (imm & 0x3f));
  INSTPAT("010000? ????? ????? 101 ????? 00100 11", srai, I, R(rd) = (sword_t)src1 >> (imm & 0x3f));

  INSTPAT("??????? ????? ????? 000 ????? 00110 11", addiw, I, R(rd) = SEXT((uint32_t)src1 + imm, 32));

  INSTPAT("0000000 ????? ????? 001 ????? 00110 11", slliw, I, R(rd) = SEXT((uint32_t)src1 << (imm & 0x1f), 32));
  INSTPAT("0000000 ????? ????? 101 ????? 00110 11", srliw, I, R(rd) = SEXT((uint32_t)src1 >> (imm & 0x1f), 32));
  INSTPAT("0100000 ????? ????? 101 ????? 00110 11", sraiw, I, R(rd) = SEXT((int32_t)src1 >> (imm & 0x1f), 32));
  INSTPAT("0000000 ????? ????? 000 ????? 01110 11", addw, R, R(rd) = SEXT((int32_t)src1 + (int32_t)src2, 32));
  INSTPAT("0100000 ????? ????? 000 ????? 01110 11", subw, R, R(rd) = SEXT((int32_t)src1 - (int32_t)src2, 32));
  INSTPAT("0000000 ????? ????? 001 ????? 01110 11", sllw, R, R(rd) = SEXT((uint32_t)src1 << ((uint32_t)src2), 32));
  INSTPAT("0000000 ????? ????? 101 ????? 01110 11", srlw, R, R(rd) = SEXT((uint32_t)src1 >> ((uint32_t)src2), 32));
  INSTPAT("0100000 ????? ????? 101 ????? 01110 11", sraw, R, R(rd) = SEXT((int32_t)src1 >> ((int32_t)src2), 32));

  // RV32/RV64 Zifencei Standard Extension
  INSTPAT("??????? ????? ????? 001 ????? 00011 11", fence_i, I, {});

  // RV32/RV64 Zicsr Standard Extension
  INSTPAT("??????? ????? ????? 001 ????? 11100 11", csrrw, I, { if (csr_valid(s, imm)) {R(rd) = CSR(imm); CSR(imm) = src1; } });
  INSTPAT("??????? ????? ????? 010 ????? 11100 11", csrrs, I, { if (csr_valid(s, imm)) {R(rd) = CSR(imm); if (rs1 != 0) { CSR(imm) = CSR(imm) | src1;}; } });
  INSTPAT("??????? ????? ????? 011 ????? 11100 11", csrrc, I, { if (csr_valid(s, imm)) {R(rd) = CSR(imm); if (rs1 != 0) { CSR(imm) = CSR(imm) & ~src1;}; } });
  INSTPAT("??????? ????? ????? 101 ????? 11100 11", csrrwi, I_I, { if (csr_valid(s, imm)) { R(rd) = CSR(imm); CSR(imm) = src1;} });
  INSTPAT("??????? ????? ????? 110 ????? 11100 11", csrrsi, I_I, { if (csr_valid(s, imm)) { R(rd) = CSR(imm); if (rs1 != 0) { CSR(imm) = CSR(imm) | src1; };} });
  INSTPAT("??????? ????? ????? 111 ????? 11100 11", csrrci, I_I, { if (csr_valid(s, imm)) { R(rd) = CSR(imm); if (rs1 != 0) { CSR(imm) = CSR(imm) & ~src1; };} });

  // RV32M Standard Extension
  INSTPAT("0000001 ????? ????? 000 ????? 01100 11", mul, R, R(rd) = src1 * src2);
  INSTPAT("0000001 ????? ????? 001 ????? 01100 11", mulh, R, R(rd) = ((int64_t)(sword_t)src1 * (int64_t)(sword_t)src2) >> 32);
  INSTPAT("0000001 ????? ????? 010 ????? 01100 11", mulhsu, R, R(rd) = ((int64_t)(sword_t)src1 * (int64_t)(word_t)src2) >> 32);
  INSTPAT("0000001 ????? ????? 011 ????? 01100 11", mulhu, R, R(rd) = ((int64_t)(word_t)src1 * (int64_t)(word_t)src2) >> 32);
  INSTPAT("0000001 ????? ????? 100 ????? 01100 11", div, R, R(rd) = ((sword_t)src2 == 0) ? ~0 : (sword_t)src1 / (sword_t)src2);
  INSTPAT("0000001 ????? ????? 101 ????? 01100 11", divu, R, R(rd) = ((word_t)src2 == 0) ? ~0 : (word_t)src1 / (word_t)src2);
  INSTPAT("0000001 ????? ????? 110 ????? 01100 11", rem, R, R(rd) = (sword_t)src1 % (sword_t)src2);
  INSTPAT("0000001 ????? ????? 111 ????? 01100 11", remu, R, R(rd) = (word_t)src1 % (word_t)src2);

  // RV64M Standard Extension
  INSTPAT("0000001 ????? ????? 000 ????? 01110 11", mulw, R, R(rd) = SEXT((int32_t)src1 * (int32_t)src2, 32));
  INSTPAT("0000001 ????? ????? 100 ????? 01110 11", divw, R, R(rd) = SEXT((int32_t)src1 / (int32_t)src2, 32));
  INSTPAT("0000001 ????? ????? 101 ????? 01110 11", divuw, R, R(rd) = SEXT((uint32_t)src1 / (uint32_t)src2, 32));
  INSTPAT("0000001 ????? ????? 110 ????? 01110 11", remw, R, R(rd) = SEXT((int32_t)src1 % (int32_t)src2, 32));
  INSTPAT("0000001 ????? ????? 111 ????? 01110 11", remuw, R, R(rd) = SEXT((uint32_t)src1 % (uint32_t)src2, 32));

  // RV32A Standard Extension
  INSTPAT("00010?? 00000 ????? 010 ????? 01011 11", lr.w, R, { R(rd) = Mr(src1, 4); cpu.reservation = get_paddr(src1, 4); });
  INSTPAT("00011?? ????? ????? 010 ????? 01011 11", sc.w, R, { 
    if (cpu.reservation == get_paddr(src1, 4)) { R(rd) = 0; Mw(src1, 4, src2); } else { R(rd) = 1; }; cpu.reservation = 0; });
  INSTPAT("00001?? ????? ????? 010 ????? 01011 11", amoswap.w, R, {sword_t tmp = Mr(src1, 4);Mw(src1, 4, src2);R(rd) = tmp; });
  INSTPAT("00000?? ????? ????? 010 ????? 01011 11", amoadd.w, R, {sword_t tmp = Mr(src1, 4);Mw(src1, 4, src2 + tmp);R(rd) = SEXT(tmp, 32); });
  INSTPAT("00100?? ????? ????? 010 ????? 01011 11", amoxor.w, R, { sword_t tmp = Mr(src1, 4); Mw(src1, 4, src2 ^ tmp); R(rd) = SEXT(tmp, 32); });
  INSTPAT("01100?? ????? ????? 010 ????? 01011 11", amoand.w, R, { sword_t tmp = Mr(src1, 4); Mw(src1, 4, src2 & tmp); R(rd) = SEXT(tmp, 32); });
  INSTPAT("01000?? ????? ????? 010 ????? 01011 11", amoor.w, R, { sword_t tmp = Mr(src1, 4); Mw(src1, 4, src2 | tmp); R(rd) = SEXT(tmp, 32); });
  INSTPAT("10000?? ????? ????? 010 ????? 01011 11", amomin.w, R, {sword_t tmp = Mr(src1, 4);Mw(src1, 4, (tmp < src2) ? tmp : src2);R(rd) = SEXT(tmp, 32); });
  INSTPAT("10100?? ????? ????? 010 ????? 01011 11", amomax.w, R, {sword_t tmp = Mr(src1, 4);Mw(src1, 4, (tmp > src2) ? tmp : src2);R(rd) = SEXT(tmp, 32); });
  INSTPAT("11000?? ????? ????? 010 ????? 01011 11", amominu.w, R, {sword_t tmp = Mr(src1, 4);Mw(src1, 4, (tmp < src2) ? src2 : tmp);R(rd) = SEXT(tmp, 32); });
  INSTPAT("11100?? ????? ????? 010 ????? 01011 11", amomaxu.w, R, {sword_t tmp = Mr(src1, 4);Mw(src1, 4, (tmp > src2) ? src2 : tmp);R(rd) = SEXT(tmp, 32); });

  // RV64A Standard Extension
  INSTPAT("00010?? 00000 ????? 011 ????? 01011 11", lr.d, R, R(rd) = Mr(src1, 8));
  INSTPAT("00011?? ????? ????? 011 ????? 01011 11", sc.d, R, R(rd) = 0; Mw(src1, 8, src2););
  INSTPAT("00001?? ????? ????? 011 ????? 01011 11", amoswap.d, R, {sword_t tmp = Mr(src1, 8);Mw(src1, 8, src2);R(rd) = tmp; });
  INSTPAT("00000?? ????? ????? 011 ????? 01011 11", amoadd.d, R, {sword_t tmp = Mr(src1, 8);Mw(src1, 8, src2 + tmp);R(rd) = tmp; });
  INSTPAT("00100?? ????? ????? 011 ????? 01011 11", amoxor.d, R, {sword_t tmp = Mr(src1, 8);Mw(src1, 8, src2 ^ tmp);R(rd) = tmp; });
  INSTPAT("01100?? ????? ????? 011 ????? 01011 11", amoand.d, R, {sword_t tmp = Mr(src1, 8);Mw(src1, 8, src2 & tmp);R(rd) = tmp; });
  INSTPAT("01000?? ????? ????? 011 ????? 01011 11", amoor.d, R, {sword_t tmp = Mr(src1, 8);Mw(src1, 8, src2 | tmp);R(rd) = tmp; });
  INSTPAT("10000?? ????? ????? 011 ????? 01011 11", amomin.d, R, {sword_t tmp = Mr(src1, 8);Mw(src1, 8, (tmp < src2) ? tmp : src2);R(rd) = tmp; });
  INSTPAT("10100?? ????? ????? 011 ????? 01011 11", amomax.d, R, {sword_t tmp = Mr(src1, 8);Mw(src1, 8, (tmp > src2) ? tmp : src2);R(rd) = tmp; });
  INSTPAT("11000?? ????? ????? 011 ????? 01011 11", amominu.d, R, {sword_t tmp = Mr(src1, 8);Mw(src1, 8, (tmp < src2) ? src2 : tmp);R(rd) = tmp; });
  INSTPAT("11100?? ????? ????? 011 ????? 01011 11", amomaxu.d, R, {sword_t tmp = Mr(src1, 8);Mw(src1, 8, (tmp > src2) ? src2 : tmp);R(rd) = tmp; });

  // Trap-Return Instructions
  INSTPAT("0011000 00010 00000 000 00000 11100 11", mret, N, s->dnpc = CSR(CSR_MEPC);
          csr_t reg = {.val = CSR(CSR_MSTATUS)};
          cpu.last_inst_priv = cpu.priv;
          cpu.priv = reg.mstatus.mpp;
          reg.mstatus.mie = reg.mstatus.mpie;
          reg.mstatus.mpie = 1;
          reg.mstatus.mpp = PRV_U;
          // printf(" mret: priv: %d, mstatus_p: " FMT_WORD_NO_PREFIX ", mstatus: " FMT_WORD "\n",
          //        cpu.priv, CSR(CSR_MSTATUS), reg.val);
          CSR(CSR_MSTATUS) = reg.val;);
  INSTPAT("0001000 00010 00000 000 00000 11100 11", sret, N, s->dnpc = CSR(CSR_SEPC);
          csr_t reg = {.val = CSR(CSR_MSTATUS)};
          cpu.last_inst_priv = cpu.priv;
          cpu.priv = reg.mstatus.spp;
          reg.mstatus.mie = reg.mstatus.mpie;
          reg.mstatus.sie = 1;
          reg.mstatus.spp = 0;
          reg.mstatus.mpp = PRV_S;
          // printf(" mret: priv: %d, mstatus_p: " FMT_WORD_NO_PREFIX ", mstatus: " FMT_WORD "\n",
          //        cpu.priv, CSR(CSR_MSTATUS), reg.val);
          CSR(CSR_SSTATUS) = reg.val;);
  // Interrupt-Management Instructions
  INSTPAT("0001000 00101 00000 000 00000 11100 11", wfi, N, { difftest_skip_ref(); });
  INSTPAT("0001001 ????? ????? 000 00000 11100 11", sfence.vma, N, {});

  INSTPAT("??????? ????? ????? ??? ????? ????? ??", inv, N, { if (CSR(CSR_MTVEC)) { s->dnpc = isa_raise_intr(MCA_ILL_INS, s->pc); } else {  INV(s->pc);} });
  INSTPAT_END();

#ifdef CONFIG_RV64
  CSR(CSR_MSTATUS) = CSR(CSR_MSTATUS) & 0x800000FF007FFFEA;
#else
  CSR(CSR_MSTATUS) = CSR(CSR_MSTATUS) & 0x807FFFEA;
#endif
  CSR(CSR_MISA) = CSR_MISA_VALUE;
  CSR(CSR_MEDELEG) &= 0x1ffff;
  if ((cpu.last_inst_priv == PRV_S && cpu.priv != PRV_M) || cpu.priv == PRV_S)
  {
    csr_t reg_mstatus = {.val = CSR(CSR_MSTATUS)};
    csr_t reg_sstatus = {.val = CSR(CSR_SSTATUS)};
    reg_mstatus.mstatus.sie = reg_sstatus.mstatus.sie;
    reg_mstatus.mstatus.spie = reg_sstatus.mstatus.spie;
    reg_mstatus.mstatus.ube = reg_sstatus.mstatus.ube;
    reg_mstatus.mstatus.spp = reg_sstatus.mstatus.spp;
    reg_mstatus.mstatus.vs = reg_sstatus.mstatus.vs;
    reg_mstatus.mstatus.fs = reg_sstatus.mstatus.fs;
    reg_mstatus.mstatus.xs = reg_sstatus.mstatus.xs;
    reg_mstatus.mstatus.sum = reg_sstatus.mstatus.sum;
    reg_mstatus.mstatus.mxr = reg_sstatus.mstatus.mxr;
    reg_mstatus.mstatus.sd = reg_sstatus.mstatus.sd;
    CSR(CSR_MSTATUS) = reg_mstatus.val;
    csr_t reg_mie = {.val = CSR(CSR_MIE)};
    csr_t reg_sie = {.val = CSR(CSR_SIE)};
    reg_mie.mie.ssie = reg_sie.sie.ssie;
    reg_mie.mie.stie = reg_sie.sie.stie;
    reg_mie.mie.seie = reg_sie.sie.seie;
    reg_mie.mie.lcofie = reg_sie.sie.lcofie;
    CSR(CSR_MIE) = reg_mie.val;
  }
  CSR(CSR_SSTATUS) = CSR(CSR_MSTATUS) & 0x800de762;
  CSR(CSR_SIE) = CSR(CSR_MIE) & 0x2666;

  CSR(CSR_TIME) = CSR(CSR_TIME) + 0x1;
  CSR(CSR_MCYCLE) = CSR(CSR_MCYCLE) + 0x1;
  if (CSR(CSR_TIME) == ~0)
  {
    CSR(CSR_TIME) = 0;
    CSR(CSR_TIMEH) = CSR(CSR_TIMEH) + 0x1;
  }
  csr_t reg_mie = {.val = CSR(CSR_MIE)};
  csr_t reg_mstatus = {.val = CSR(CSR_MSTATUS)};
  cpu.mtimecmp = get_mtimecmp();
  if (CSR(CSR_TIME) >= cpu.mtimecmp &&
      reg_mstatus.mstatus.mie)
  {
    if (cpu.priv == PRV_M && reg_mie.mie.mtie)
    {
      cpu.intr = 1;
    }
    if (cpu.priv == PRV_S &&
        reg_mie.mie.stie && reg_mstatus.mstatus.sie)
    {
      cpu.intr = 1;
    }
  }

  R(0) = 0; // reset $zero to 0

  uint32_t opcode = BITS(s->isa.inst, 6, 0);
  // jalr: 0b1100111 ; jal: 0b1101111
  if (opcode == 0b1100111 || opcode == 0b1101111 ||
      s->isa.inst == 0x00000073 || s->isa.inst == 0x30200073)
  {
    ftracebuf[ftracehead].pc = s->pc;
    ftracebuf[ftracehead].npc = s->dnpc;
    // jalr x0, 0(x1): 0x00008067, a.k.a. ret
    // mret: 0x30200073
    if (s->isa.inst == 0x00008067 || s->isa.inst == 0x30200073)
    {
      ftracebuf[ftracehead].ret = true;
      ftracedepth--;
      ftracebuf[ftracehead].depth = ftracedepth;
    }
    else
    {
      ftracebuf[ftracehead].ret = false;
      ftracebuf[ftracehead].depth = ftracedepth;
      ftracedepth++;
    }
    ftracehead = (ftracehead + 1) % MAX_FTRACE_SIZE;
  }
  return 0;
}

jmp_buf exec_jmp_buf;
int cause;

int isa_exec_once(Decode *s)
{
  // instruction fetch
  int jmp_value = setjmp(exec_jmp_buf);
  if (jmp_value)
  {
    // printf("if longjmp(%d), cause: %d, pc: " FMT_WORD_NO_PREFIX "\n", jmp_value, cause, s->pc);
    s->dnpc = isa_raise_intr(cause, s->pc);
    return 0;
  }
  s->isa.inst = inst_fetch(&s->snpc, 4);
  cpu.inst = s->isa.inst;

  // instruction decode and execute
  jmp_value = setjmp(exec_jmp_buf);
  if (jmp_value)
  {
    // printf("de longjmp(%2d), cause: %d, pc: " FMT_WORD_NO_PREFIX ", inst: " FMT_WORD_NO_PREFIX "\n",
    //        jmp_value, cause, s->pc, s->isa.inst);
    s->dnpc = isa_raise_intr(cause, s->pc);
    return 0;
  }
  return decode_exec(s);
}

void isa_parser_elf(char *filename)
{
  FILE *fp = fopen(filename, "rb");
  Assert(fp, "Can not open '%s'", filename);
  fseek(fp, 0, SEEK_END);
  long size = ftell(fp);
  Assert(size < MAX_ELF_SIZE, "elf file is too large");

  fseek(fp, 0, SEEK_SET);
  int ret = fread(&elf_ehdr, sizeof(elf_ehdr), 1, fp);
  assert(ret == 1);
  assert(memcmp(elf_ehdr.e_ident, ELFMAG, SELFMAG) == 0);
  fseek(fp, 0, SEEK_SET);
  ret = fread(elfbuf, size, 1, fp);
  assert(ret == 1);
  fclose(fp);

  printf("e_ident: ");
  for (size_t i = 0; i < SELFMAG; i++)
  {
    printf("%02x ", elf_ehdr.e_ident[i]);
  }
  printf("\n");
  printf("e_type: %d\t", elf_ehdr.e_type);
  printf("e_machine: %d\t", elf_ehdr.e_machine);
  printf("e_version: %d\n", elf_ehdr.e_version);
  printf("e_entry: " FMT_WORD "\t", elf_ehdr.e_entry);
  printf("e_phoff: " FMT_WORD "\n", elf_ehdr.e_phoff);
  printf("e_shoff: " FMT_WORD "\t", elf_ehdr.e_shoff);
  printf("e_flags: 0x%016x\n", elf_ehdr.e_flags);
  printf("e_ehsize: %d\t", elf_ehdr.e_ehsize);
  printf("e_phentsize: %d\t", elf_ehdr.e_phentsize);
  printf("e_phnum: %d\n", elf_ehdr.e_phnum);
  printf("e_shentsize: %d\t", elf_ehdr.e_shentsize);
  printf("e_shnum: %d\t", elf_ehdr.e_shnum);
  printf("e_shstrndx: %d\n", elf_ehdr.e_shstrndx);

  for (size_t i = 0; i < elf_ehdr.e_shnum; i++)
  {
    Elf_Shdr *shdr = (Elf_Shdr *)(elfbuf + elf_ehdr.e_shoff + i * elf_ehdr.e_shentsize);
    if (shdr->sh_type == SHT_SYMTAB)
    {
      elfshdr_symtab = shdr;
    }
    else if (shdr->sh_type == SHT_STRTAB)
    {
      elfshdr_strtab = shdr;
    }
    if (elfshdr_symtab != NULL && elfshdr_strtab != NULL)
    {
      break;
      for (size_t j = 0; j < elfshdr_symtab->sh_size / sizeof(Elf_Sym); j++)
      {
        Elf_Sym *sym = (Elf_Sym *)(elfbuf + elfshdr_symtab->sh_offset + j * sizeof(Elf_Sym));
        printf("" FMT_WORD ": %s\n", sym->st_value, elfbuf + elfshdr_strtab->sh_offset + sym->st_name);
      }
      break;
    }
  }
}

void cpu_show_ftrace()
{
  Elf_Sym *sym = NULL;
  Ftrace *ftrace = NULL;
  for (size_t i = 0; i < ftracehead; i++)
  {
    ftrace = ftracebuf + i;
    printf("" FMT_WORD_NO_PREFIX ": ", ftrace->pc);
    for (size_t j = 0; j < ftrace->depth; j++)
    {
      printf(" ");
    }
    printf("%s ", ftrace->ret ? "ret" : "call");
    if (elfshdr_symtab == NULL)
    {
      printf("\n");
      continue;
    }
    for (int j = elfshdr_symtab->sh_size / sizeof(Elf_Sym) - 1; j >= 0; j--)
    {
      sym = (Elf_Sym *)(elfbuf + elfshdr_symtab->sh_offset + j * sizeof(Elf_Sym));
      if (sym->st_value == ftrace->npc)
      {
        break;
      }
    }
    printf(
        "[%s@" FMT_WORD "]\n",
        elfbuf + elfshdr_strtab->sh_offset + sym->st_name,
        ftrace->npc);
  }
}
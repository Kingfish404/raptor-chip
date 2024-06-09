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

#ifndef __ISA_RISCV_H__
#define __ISA_RISCV_H__

#include <common.h>

// Machine Trap Settup
#define CSR_MSTATUS 0x300
#define CSR_MTVEC   0x305

// Machine Trap Handling
#define CSR_MEPC    0x341
#define CSR_MCAUSE  0x342

// CSR_MSTATUS FLAGS
#define CSR_MSTATUS_MPP   0x1800
#define CSR_MSTATUS_MPIE  0x80
#define CSR_MSTATUS_MIE  0x8

// Machine Information Registers
#define CSR_MVENDORID 0xf11
#define CSR_MARCHID 0xf12

#define CSR_SET(REG, BIT_MASK) {cpu.sr[REG] |= BIT_MASK;}

#define CSR_CLEAR(REG, BIT_MASK) {cpu.sr[REG] &= ~BIT_MASK;}


#define CSR_BIT_COND_SET(REG, COND, BIT_MASK) \
{do { \
  CSR_CLEAR(REG, BIT_MASK) \
  if ((cpu.sr[REG] & COND) > 0) { \
    CSR_SET(REG, BIT_MASK) \
  } \
} while (0);}

typedef struct {
  word_t sr[4096];
  word_t gpr[MUXDEF(CONFIG_RVE, 16, 32)];
  vaddr_t pc;
  uint32_t inst;
} MUXDEF(CONFIG_RV64, riscv64_CPU_state, riscv32_CPU_state);

// decode
typedef struct {
  union {
    uint32_t val;
  } inst;
} MUXDEF(CONFIG_RV64, riscv64_ISADecodeInfo, riscv32_ISADecodeInfo);

#define isa_mmu_check(vaddr, len, type) (MMU_DIRECT)

#endif

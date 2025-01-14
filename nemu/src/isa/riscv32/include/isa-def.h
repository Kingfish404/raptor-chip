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

// RISC-V privilege levels
#define PRV_U 0
#define PRV_S 1
#define PRV_M 3

// RISC-V supervisor-level CSR addresses
#define CSR_SATP 0x180

// Machine Trap Settup
#define CSR_MSTATUS 0x300
#define CSR_MTVEC 0x305

// Machine Trap Handling
#define CSR_MEPC 0x341
#define CSR_MCAUSE 0x342

// CSR_MSTATUS FLAGS
#define CSR_MSTATUS_MPP 0x1800
#define CSR_MSTATUS_MPIE 0x80
#define CSR_MSTATUS_MIE 0x8

// Machine Information Registers
#define CSR_MVENDORID 0xf11
#define CSR_MARCHID 0xf12

#if defined(CONFIG_RV64)
#error "RV64 is not supported"
#else
// !important: only Little-Endian is supported
typedef union
{
  struct
  {
    word_t rev1 : 1;
    word_t sie : 1;
    word_t rev2 : 1;
    word_t mie : 1;
    word_t rev3 : 1;
    word_t spie : 1;
    word_t ube : 1;
    word_t mpie : 1;
    word_t spp : 1;
    word_t vs : 2;
    word_t mpp : 2;
    word_t fs : 2;
    word_t xs : 2;
    word_t mprv : 1;
    word_t sum : 1;
    word_t mxr : 1;
    word_t tvm : 1;
    word_t tw : 1;
    word_t tsr : 1;
    word_t rev4 : 8;
    word_t sd : 1;
  } mstatus;
  struct
  {
    word_t ppn : 22;
    word_t asid : 9;
    word_t mode : 1;
  } satp;
  word_t val;
} csr_t;
#endif

#define CSR_SET__(REG, BIT_MASK) \
  {                              \
    cpu.sr[REG] |= BIT_MASK;     \
  }

#define CSR_CLEAR(REG, BIT_MASK) \
  {                              \
    cpu.sr[REG] &= ~BIT_MASK;    \
  }

#define CSR_BIT_COND_SET(REG, COND, BIT_MASK) \
  {                                           \
    do                                        \
    {                                         \
      CSR_CLEAR(REG, BIT_MASK)                \
      if ((cpu.sr[REG] & COND) > 0)           \
      {                                       \
        CSR_SET__(REG, BIT_MASK)              \
      }                                       \
    } while (0);                              \
  }

typedef struct
{
  word_t sr[4096];
  word_t gpr[MUXDEF(CONFIG_RVE, 16, 32)];
  vaddr_t pc;
  vaddr_t cpc; // for difftest.ref
  uint32_t inst;
  uint32_t priv;
} MUXDEF(CONFIG_RV64, riscv64_CPU_state, riscv32_CPU_state);

// decode
typedef struct
{
  union
  {
    uint32_t val;
  } inst;
} MUXDEF(CONFIG_RV64, riscv64_ISADecodeInfo, riscv32_ISADecodeInfo);

// #define isa_mmu_check(vaddr, len, type) (MMU_DIRECT)

#endif

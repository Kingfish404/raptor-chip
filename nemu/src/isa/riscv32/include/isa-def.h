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
enum PRV
{
  PRV_U = 0,
  PRV_S = 1,
  PRV_M = 3,
};

typedef enum
{
  // 32-bit instruction type
  TYPE_R,
  TYPE_I,
  TYPE_I_I,
  TYPE_S,
  TYPE_B,
  TYPE_U,
  TYPE_J,
  // 16-bit C extension subtype
  TYPE_CR,
  TYPE_CI,
  TYPE_CSS,
  TYPE_CIW,
  TYPE_CL,
  TYPE_CS,
  TYPE_CA,
  TYPE_CB,
  TYPE_CJ,
  TYPE_N,
} Inst_type;

#define CSR_MISA_VALUE 0x40141105

enum CSR
{
  // Supervisor-level CSR
  CSR_SSTATUS = 0x100,
  CSR_SIE = 0x104,
  CSR_STVEC = 0x105,

  CSR_SCOUNTEREN = 0x106,

  CSR_SSCRATCH = 0x140,
  CSR_SEPC = 0x141,
  CSR_SCAUSE = 0x142,
  CSR_STVAL = 0x143,
  CSR_SIP = 0x144,
  CSR_SATP = 0x180,

  // Machine Trap Settup
  CSR_MSTATUS = 0x300,
  CSR_MISA = 0x301,
  CSR_MEDELEG = 0x302,
  CSR_MIDELEG = 0x303,
  CSR_MIE = 0x304,
  CSR_MTVEC = 0x305,

  CSR_MSTATUSH = 0x310,

  // Machine Trap Handling
  CSR_MSCRATCH = 0x340,
  CSR_MEPC = 0x341,
  CSR_MCAUSE = 0x342,
  CSR_MTVAL = 0x343,
  CSR_MIP = 0x344,

  CSR_MCYCLE = 0xb00,
  CSR_TIME = 0xc01,
  CSR_TIMEH = 0xc81,

  // Machine Information Registers
  CSR_MVENDORID = 0xf11,
  CSR_MARCHID = 0xf12,
  CSR_IMPID = 0xf13,
  CSR_MHARTID = 0xf14,
};

// CSR_MSTATUS FLAGS
enum CSR_MSTATUS
{
  CSR_MSTATUS_MPRV = 0x20000,
  CSR_MSTATUS_MPP = 0x1800,
  CSR_MSTATUS_SPP = 0x100,
  CSR_MSTATUS_MPIE = 0x80,
  CSR_MSTATUS_MIE = 0x8,
};

#if defined(CONFIG_RV64)
#error "RV64 is not supported"
#define XLEN 64
#else
#define XLEN 32
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
  struct
  {
    word_t rev1 : 1;
    word_t ssie : 1;
    word_t rev2 : 3;
    word_t stie : 1;
    word_t rev3 : 3;
    word_t seie : 1;
    word_t rev4 : 3;
    word_t lcofie : 1;
  } sie;
  struct
  {
    word_t rev1 : 1;
    word_t ssie : 1;
    word_t rev2 : 3;
    word_t stie : 1;
    word_t vstie : 1;
    word_t mtie : 1;
    word_t rev3 : 1;
    word_t seie : 1;
    word_t vseie : 1;
    word_t mteie : 1;
    word_t sgeie : 1;
    word_t lcofie : 1;
  } mie;
  word_t val;
} csr_t;
#endif

// Machine cause register (mcause) values after trap.
enum MCAUSE
{
  MCA_SUP_SOF_INT = 0x1 | (1 << (XLEN - 1)),
  MCA_MAC_SOF_INT = 0x3 | (1 << (XLEN - 1)),

  MCA_SUP_TIM_INT = 0x5 | (1 << (XLEN - 1)),
  MCA_MAC_TIM_INT = 0x7 | (1 << (XLEN - 1)),

  MCA_SUP_EXT_INT = 0x9 | (1 << (XLEN - 1)),
  MCA_MAC_EXT_INT = 0xb | (1 << (XLEN - 1)),

  MCA_COU_OVE_INT = 0xd | (1 << (XLEN - 1)),

  MCA_INS_ADD_MIS = 0x0,
  MCA_INS_ACC_FAU = 0x1,
  MCA_ILLEGAL_INS = 0x2,

  MCA_BREAK_POINT = 0x3,

  MCA_LOA_ADD_MIS = 0x4,
  MCA_LOA_ACC_FAU = 0x5,
  MCA_STO_ADD_MIS = 0x6,
  MCA_STO_ACC_FAU = 0x7,

  MCA_ENV_CAL_UMO = 0x8,
  MCA_ENV_CAL_SMO = 0x9,

  MCA_ENV_CAL_MMO = 0xb,
  MCA_INS_PAG_FAU = 0xc,
  MCA_LOA_PAG_FAU = 0xd,

  MCA_STO_PAG_FAU = 0xf,

  MCA_SOF_CHE = 0x12,
  MCA_HAR_ERR = 0x13,
};

// Supervisor cause register (scause) values after trap.
enum SCAUSE
{
  SCA_SUP_SOF_INT = 1 | (1 << (XLEN - 1)),
  SCA_SUP_TIM_INT = 5 | (1 << (XLEN - 1)),

  SCA_SUP_EXT_INT = 9 | (1 << (XLEN - 1)),
  SCA_COU_OVE_INT = 11 | (1 << (XLEN - 1)),

  SCA_INS_ADD_MIS = 0x0,
  SCA_INS_ACC_FAU = 0x1,
  SCA_ILLEGAL_INS = 0x2,

  SCA_BREAK_POINT = 0x3,

  SCA_LOA_ADD_MIS = 0x4,
  SCA_LOA_ACC_FAU = 0x5,
  SCA_STO_ADD_MIS = 0x6,
  SCA_STO_ACC_FAU = 0x7,

  SCA_ENV_CAL_UMO = 0x8,
  SCA_ENV_CAL_SMO = 0x9,

  SCA_INS_PAG_FAU = 0xc,
  SCA_LOA_PAG_FAU = 0xd,

  SCA_STO_PAG_FAU = 0xf,

  SCA_SOF_CHE = 0x12,
  SCA_HAR_ERR = 0x13,
};

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
  bool intr;
  word_t raise_intr;
  uint32_t last_inst_priv;
  uint64_t mtimecmp;
  vaddr_t reservation;

  vaddr_t vwaddr;
  word_t pwaddr;
  word_t wdata;
  word_t len;

  word_t iomm_addr; // for iomm
  word_t skip;      // for iomm
} MUXDEF(CONFIG_RV64, riscv64_CPU_state, riscv32_CPU_state);

// decode
typedef struct
{
  uint32_t inst;
} MUXDEF(CONFIG_RV64, riscv64_ISADecodeInfo, riscv32_ISADecodeInfo);

// #define isa_mmu_check(vaddr, len, type) (MMU_DIRECT)

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

#endif

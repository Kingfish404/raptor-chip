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
#include <isa-extensions.h>
#include <riscv-state.h>

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

#if defined(CONFIG_RV_F)
#define CSR_MISA_F_VALUE 0x20
#else
#define CSR_MISA_F_VALUE 0
#endif
#if defined(CONFIG_RV_D)
#define CSR_MISA_D_VALUE 0x08
#else
#define CSR_MISA_D_VALUE 0
#endif
#if defined(CONFIG_RV_F) && defined(CONFIG_RV_D) && !defined(CONFIG_RVE)
#define CSR_MISA_V_VALUE (riscv_v128_preview_enabled() ? 0x200000 : 0)
#else
#define CSR_MISA_V_VALUE 0
#endif
#if defined(CONFIG_RV64)
#define CSR_MISA_H_VALUE (riscv_h_gstage_preview_enabled() ? 0x80 : 0)
#define CSR_MISA_VALUE (0x8000000000141107ULL | CSR_MISA_F_VALUE | CSR_MISA_D_VALUE | \
                        CSR_MISA_V_VALUE | CSR_MISA_H_VALUE)
#else
#define CSR_MISA_VALUE (0x40141107 | CSR_MISA_F_VALUE | CSR_MISA_D_VALUE | CSR_MISA_V_VALUE)
#endif

#define CSR_MISA_EXT_D ((word_t)1 << 3)
#define CSR_MISA_EXT_F ((word_t)1 << 5)
#define CSR_MSTATUS_FS_MASK ((word_t)3 << 13)
#define CSR_MSTATUS_VS_MASK ((word_t)3 << 9)
#define CSR_HSTATUS_VTVM ((word_t)1 << 20)
#define CSR_HSTATUS_VTW ((word_t)1 << 21)
#define CSR_HSTATUS_VTSR ((word_t)1 << 22)

enum CSR
{
  // Floating-point CSRs (F extension)
  CSR_FFLAGS = 0x001,
  CSR_FRM = 0x002,
  CSR_FCSR = 0x003,
  CSR_VSTART = 0x008,
  CSR_VXSAT = 0x009,
  CSR_VXRM = 0x00a,
  CSR_VCSR = 0x00f,

  // Supervisor-level CSR
  CSR_SSTATUS = 0x100,
  CSR_SIE = 0x104,
  CSR_STVEC = 0x105,

  CSR_SCOUNTEREN = 0x106,
  CSR_SENVCFG = 0x10a,
  CSR_SSTATEEN0 = 0x10c,
  CSR_SSTATEEN3 = 0x10f,

  CSR_SSCRATCH = 0x140,
  CSR_SEPC = 0x141,
  CSR_SCAUSE = 0x142,
  CSR_STVAL = 0x143,
  CSR_SIP = 0x144,
  CSR_SATP = 0x180,
  CSR_SCOUNTOVF = 0xda0,

  CSR_VSSTATUS = 0x200,
  CSR_VSIE = 0x204,
  CSR_VSTVEC = 0x205,
  CSR_VSSCRATCH = 0x240,
  CSR_VSEPC = 0x241,
  CSR_VSCAUSE = 0x242,
  CSR_VSTVAL = 0x243,
  CSR_VSIP = 0x244,
  CSR_VSTIMECMP = 0x24d,
  CSR_VSATP = 0x280,
  CSR_HSTATUS = 0x600,
  CSR_HEDELEG = 0x602,
  CSR_HIDELEG = 0x603,
  CSR_HIE = 0x604,
  CSR_HTIMEDELTA = 0x605,
  CSR_HCOUNTEREN = 0x606,
  CSR_HGEIE = 0x607,
  CSR_HENVCFG = 0x60a,
  CSR_HSTATEEN0 = 0x60c,
  CSR_HSTATEEN3 = 0x60f,
  CSR_HTVAL = 0x643,
  CSR_HTINST = 0x64a,
  CSR_HIP = 0x644,
  CSR_HVIP = 0x645,
  CSR_HGATP = 0x680,
  CSR_HGEIP = 0xe12,

  // Machine Trap Settup
  CSR_MSTATUS = 0x300,
  CSR_MISA = 0x301,
  CSR_MEDELEG = 0x302,
  CSR_MIDELEG = 0x303,
  CSR_MIE = 0x304,
  CSR_MTVEC = 0x305,
  CSR_MCOUNTEREN = 0x306,
  CSR_MCOUNTINHIBIT = 0x320,

  CSR_MENVCFG = 0x30a,
  CSR_MSTATEEN0 = 0x30c,
  CSR_MSTATEEN3 = 0x30f,
  CSR_MENVCFGH = 0x31a,
  CSR_MSTATEEN0H = 0x31c,
  CSR_MSTATEEN3H = 0x31f,
  CSR_MSTATUSH = 0x310,

  // Machine Trap Handling
  CSR_MSCRATCH = 0x340,
  CSR_MEPC = 0x341,
  CSR_MCAUSE = 0x342,
  CSR_MTVAL = 0x343,
  CSR_MTINST = 0x34a,
  CSR_MTVAL2 = 0x34b,
  CSR_MIP = 0x344,
  CSR_MBERR_STATUS = 0x7c0,
  CSR_MBERR_ADDR = 0xfc0,

  // PMP Configuration (read-as-zero, no PMP implemented)
  CSR_PMPCFG0 = 0x3a0,
  CSR_PMPCFG1 = 0x3a1,
  CSR_PMPCFG2 = 0x3a2,
  CSR_PMPCFG3 = 0x3a3,
  CSR_PMPADDR0 = 0x3b0,
  CSR_PMPADDR15 = 0x3bf,

  CSR_MCYCLE = 0xb00,
  CSR_MINSTRET = 0xb02,
  CSR_MCYCLEH = 0xb80,
  CSR_MINSTRETH = 0xb82,
  CSR_CYCLE_ = 0xc00,
  CSR_VL = 0xc20,
  CSR_VTYPE = 0xc21,
  CSR_VLENB = 0xc22,
  CSR_TIME = 0xc01,
  CSR_INSTRET = 0xc02,
  CSR_CYCLEH = 0xc80,
  CSR_TIMEH = 0xc81,
  CSR_INSTRETH = 0xc82,

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
#define XLEN 64
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
    word_t rev4 : 9;
    word_t uxl : 2;
    word_t sxl : 2;
    word_t sbe : 1;
    word_t mbe : 1;
    word_t rev5 : 25;
    word_t sd : 1;
  } mstatus;
  struct
  {
    word_t ppn : 44;
    word_t asid : 16;
    word_t mode : 4;
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
#define MCA_INTR_BIT ((word_t)1 << (XLEN - 1))

enum MCAUSE
{
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
  MCA_ENV_CAL_VSMO = 0xa,
  MCA_ENV_CAL_MMO = 0xb,
  MCA_INS_PAG_FAU = 0xc,
  MCA_LOA_PAG_FAU = 0xd,

  MCA_STO_PAG_FAU = 0xf,

  MCA_INS_GUEST_PAG_FAU = 0x14,
  MCA_LOA_GUEST_PAG_FAU = 0x15,
  MCA_VIRT_INS = 0x16,
  MCA_STO_GUEST_PAG_FAU = 0x17,

  MCA_SOF_CHE = 0x12,
  MCA_HAR_ERR = 0x13,
};

#ifdef CONFIG_RV64
enum {
  RISCV_GSTAGE_OK,
  RISCV_GSTAGE_PAGE_FAULT,
  RISCV_GSTAGE_ACCESS_FAULT,
};
enum {
  RISCV_VSTAGE_OK,
  RISCV_VSTAGE_PAGE_FAULT,
  RISCV_VSTAGE_GUEST_PAGE_FAULT,
  RISCV_VSTAGE_ACCESS_FAULT,
};
int riscv_gstage_translate(paddr_t guest_address, bool store, bool execute_access,
                           bool cmo, bool implicit, paddr_t *physical_address, uint8_t *pbmt);
int riscv_vstage_translate(vaddr_t guest_address, bool store, bool execute_access,
                           bool virtual_supervisor, bool cmo,
                           paddr_t *physical_address, paddr_t *fault_address,
                           bool *page_table_write, uint8_t *pbmt);
#endif
extern NEMU_TLS paddr_t riscv_h_fault_gpa;
extern NEMU_TLS bool riscv_h_fault_ptw;
extern NEMU_TLS bool riscv_h_fault_write;
extern NEMU_TLS bool riscv_h_explicit_trap;

#define MCA_SUP_SOF_INT (MCA_INTR_BIT | 0x1)
#define MCA_VSUP_SOF_INT (MCA_INTR_BIT | 0x2)
#define MCA_MAC_SOF_INT (MCA_INTR_BIT | 0x3)
#define MCA_SUP_TIM_INT (MCA_INTR_BIT | 0x5)
#define MCA_VSUP_TIM_INT (MCA_INTR_BIT | 0x6)
#define MCA_MAC_TIM_INT (MCA_INTR_BIT | 0x7)
#define MCA_SUP_EXT_INT (MCA_INTR_BIT | 0x9)
#define MCA_VSUP_EXT_INT (MCA_INTR_BIT | 0xa)
#define MCA_MAC_EXT_INT (MCA_INTR_BIT | 0xb)
#define MCA_COU_OVE_INT (MCA_INTR_BIT | 0xd)

// Supervisor cause register (scause) values after trap.
enum SCAUSE
{
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

#define SCA_SUP_SOF_INT (MCA_INTR_BIT | 1)
#define SCA_SUP_TIM_INT (MCA_INTR_BIT | 5)
#define SCA_SUP_EXT_INT (MCA_INTR_BIT | 9)
#define SCA_COU_OVE_INT (MCA_INTR_BIT | 13)

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

word_t riscv_mip_value(void);
word_t riscv_hart_mip_value(const riscv_CPU_state *hart);

static inline bool riscv_virtual_timer_pending(const riscv_CPU_state *hart)
{
#ifdef CONFIG_RV64
  return riscv_h_gstage_preview_enabled() &&
      (hart->sr[CSR_MENVCFG] & (word_t)(UINT64_C(1) << 63)) &&
      (hart->sr[CSR_HENVCFG] & (word_t)(UINT64_C(1) << 63)) &&
      (uint64_t)(hart->sr[CSR_TIME] + hart->sr[CSR_HTIMEDELTA]) >=
          (uint64_t)hart->sr[CSR_VSTIMECMP];
#else
  (void)hart;
  return false;
#endif
}

#ifdef NEMU_HAS_SMP
#define NEMU_MAX_HARTS 4
extern riscv_CPU_state cpu_harts[NEMU_MAX_HARTS];
extern NEMU_TLS riscv_CPU_state *cpu_current;
extern unsigned nemu_nr_harts;
extern NEMU_TLS unsigned nemu_hartid;
extern bool nemu_hart_waiting[NEMU_MAX_HARTS];
#define cpu (*cpu_current)
#else
#define NEMU_MAX_HARTS 1
#define nemu_nr_harts 1u
#define nemu_hartid 0u
extern NEMU_TLS riscv_CPU_state cpu;
#endif

static inline riscv_CPU_state *riscv_hart(unsigned hartid)
{
#ifdef NEMU_HAS_SMP
  return &cpu_harts[hartid];
#else
  (void)hartid;
  return &cpu;
#endif
}
/* Cheap interrupt pre-filter for the execute loop. Only a raw MIP source that
 * is also enabled in mie can ever produce a pending interrupt, so the common
 * case (nothing asserted) can skip the full isa_query_intr() call. */
static inline bool riscv_intr_may_pending(void)
{
  if (likely(cpu.sr[CSR_MIE] == 0))
    return false;
  word_t sources = cpu.sr[CSR_MIP] |
                   (cpu.sr[CSR_HVIP] & (word_t)riscv_virtual_irq_mask()) |
                   (cpu.seip ? (word_t)0x200 : 0) |
                   (cpu.stip ? (word_t)0x20 : 0);
  if (riscv_virtual_timer_pending(&cpu)) sources |= (word_t)0x40;
#ifdef CONFIG_RAPTOR_MEMORY_MAP
  sources |= (cpu.sr[CSR_MBERR_STATUS] & 1) << 16;
#endif
  return sources != 0;
}

/* Effective privilege for loads/stores: MPRV + MPP override while in M-mode.
 * Inlined here because it sits on every data access path (two calls per load
 * /store via vaddr.c); as a cross-TU extern it could not be inlined. */
static inline uint32_t pmp_effective_priv_ls(void)
{
  word_t ms = cpu.sr[CSR_MSTATUS];
  if ((ms & CSR_MSTATUS_MPRV) && cpu.priv == PRV_M)
    return (uint32_t)((ms & CSR_MSTATUS_MPP) >> 11);
  return cpu.priv;
}

static inline bool riscv_data_virtual_mode(void)
{
#ifdef CONFIG_RV64
  word_t status = cpu.sr[CSR_MSTATUS];
  return riscv_h_gstage_preview_enabled() &&
      (cpu.virt || (cpu.priv == PRV_M && (status & CSR_MSTATUS_MPRV) &&
                    ((status & CSR_MSTATUS_MPP) >> 11) != PRV_M &&
                    (status & ((word_t)1 << 39))));
#else
  return false;
#endif
}

#ifdef CONFIG_RV64
static inline word_t riscv_pointer_mask_value(word_t address, unsigned pmm, bool translated)
{
  unsigned length = pmm == 2 ? 7 : pmm == 3 ? 16 : 0;
  if (!length) return address;
  word_t mask = ~(word_t)0 >> length;
  address &= mask;
  if (translated && (address & ((word_t)1 << (63 - length)))) address |= ~mask;
  return address;
}
#endif

static inline word_t riscv_pointer_mask(word_t address)
{
#ifdef CONFIG_RV64
  if (!(riscv_isa_extensions & (NEMU_ISA_EXT_SSNPM | NEMU_ISA_EXT_SMNPM))) return address;
  uint32_t privilege = pmp_effective_priv_ls();
  bool guest = riscv_data_virtual_mode();
  word_t mxr = cpu.sr[CSR_MSTATUS] | (guest ? cpu.sr[CSR_VSSTATUS] : 0);
  if (privilege == PRV_M || (mxr & ((word_t)1 << 19))) return address;
  uint64_t extension = guest || privilege == PRV_U ? NEMU_ISA_EXT_SSNPM : NEMU_ISA_EXT_SMNPM;
  if (!(riscv_isa_extensions & extension)) return address;
  uint16_t envcfg = guest && privilege == PRV_S ? CSR_HENVCFG :
      privilege == PRV_U ? CSR_SENVCFG : CSR_MENVCFG;
  unsigned pmm = (cpu.sr[envcfg] >> 32) & 3;
  uint16_t satp = guest ? CSR_VSATP : CSR_SATP;
  return riscv_pointer_mask_value(address, pmm, (cpu.sr[satp] >> 60) != 0);
#endif
  return address;
}

// decode
typedef struct
{
  uint32_t inst;
} riscv_ISADecodeInfo;

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

// PC representation of the reference target (see RV_PC_BITS).
static inline word_t riscv_legalize_pc(word_t pc) {
#if defined(CONFIG_RV64) && defined(CONFIG_RV_PC_BITS) && CONFIG_RV_PC_BITS < 64
  const int bits = CONFIG_RV_PC_BITS;
  const int64_t upper = (int64_t)pc >> (bits - 1);
  if (upper == 0 || upper == -1) return pc;
  const word_t sign = pc >> 63;
  const word_t low = pc & (((word_t)1 << (bits - 2)) - 1);
  return (sign ? ~(((word_t)1 << (bits - 1)) - 1) : 0) | ((sign ^ 1) << (bits - 2)) | low;
#else
  return pc;
#endif
}

#endif

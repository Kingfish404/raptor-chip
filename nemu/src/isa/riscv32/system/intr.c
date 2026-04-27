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

#include <isa.h>
#include <isa-def.h>
#include <stdio.h>
#include <cpu/difftest.h>
#include <memory/tlb.h>

#if defined(CONFIG_ISA64)
// for riscv64
#define IRQ_TIMER 0x8000000000000007
#else
// for riscv32
#define IRQ_TIMER 0x80000007
#endif

extern word_t g_vaddr;

word_t isa_raise_intr(word_t NO, vaddr_t epc)
{
#ifdef CONFIG_ETRACE
  printf("ETRACE | NO: %d at epc: " FMT_WORD " trap-handler base address: " FMT_WORD,
         NO, epc, cpu.sr[CSR_MTVEC]);
#endif
  word_t tval = 0;
  // Interrupts (MSB set) always have tval=0 per RISC-V spec
  if (!(NO & MCA_INTR_BIT))
  {
    switch (NO)
    {
    case MCA_ILLEGAL_INS:
      tval = cpu.inst;
      break;
    case MCA_INS_ADD_MIS:
    case MCA_INS_ACC_FAU:
      /* For cross-boundary PMP faults, g_vaddr was set to the faulting byte
       * address in vaddr_ifetch. For other INS_ACC_FAU paths, g_vaddr equals
       * epc (set at entry to vaddr_ifetch). Matches sail mtval convention. */
      tval = g_vaddr ? g_vaddr : epc;
      break;
    case MCA_BREAK_POINT:
      tval = epc;
      break;
    case MCA_LOA_ADD_MIS:
      tval = g_vaddr;
      break;
    case MCA_LOA_ACC_FAU:
      tval = g_vaddr;
      break;
    case MCA_STO_ADD_MIS:
      tval = g_vaddr;
      break;
    case MCA_STO_ACC_FAU:
      tval = g_vaddr;
      break;
    case MCA_ENV_CAL_UMO:
    case MCA_ENV_CAL_SMO:
    case MCA_ENV_CAL_MMO:
      tval = 0;
      break;
    case MCA_INS_PAG_FAU:
      tval = epc;
      break;
    case MCA_LOA_PAG_FAU:
    case MCA_STO_PAG_FAU:
      tval = g_vaddr;
      break;
    default:
      tval = 0;
      break;
    }
  }
  word_t ret_pc = 0;
  if (cpu.priv <= PRV_S)
  {
    if ((cpu.sr[CSR_MEDELEG] & ((word_t)1 << NO)) //
        || ((NO & ((word_t)1 << (XLEN - 1)))      //
            && (cpu.sr[CSR_MIDELEG] & ((word_t)1 << (NO & ~((word_t)1 << (XLEN - 1)))))))
    {
      // printf("NO: %x, (NO & (1 << (XLEN - 1))): %x, "
      //        "(1 << (NO & ~(1 << (XLEN - 1)))): %x\n",
      //        NO, (NO & (1 << (XLEN - 1))), (1 << (NO & ~(1 << (XLEN - 1)))));
      cpu.sr[CSR_STVAL] = tval;
      cpu.sr[CSR_SEPC] = epc;
      cpu.sr[CSR_SCAUSE] = NO;

      csr_t reg_s = {.val = cpu.sr[CSR_SSTATUS]};
      reg_s.mstatus.spp = cpu.priv;
      reg_s.mstatus.spie = reg_s.mstatus.sie;
      reg_s.mstatus.sie = 0;
      cpu.sr[CSR_SSTATUS] = reg_s.val;

      csr_t reg_m = {.val = cpu.sr[CSR_MSTATUS]};
      reg_m.mstatus.spp = cpu.priv;
      reg_m.mstatus.spie = reg_m.mstatus.sie;
      reg_m.mstatus.sie = 0;
      cpu.sr[CSR_MSTATUS] = reg_m.val;

      cpu.last_inst_priv = cpu.priv;
      cpu.priv = PRV_S;
      soft_tlb_flush();
      {
        word_t stvec = cpu.sr[CSR_STVEC];
        word_t base  = stvec & ~(word_t)0x3;
        word_t mode  = stvec & 0x3;
        bool   is_int = (NO & ((word_t)1 << (XLEN - 1))) != 0;
        if (mode == 1 && is_int) {
          ret_pc = base + (word_t)((NO & ~((word_t)1 << (XLEN - 1))) * 4);
        } else {
          ret_pc = base;
        }
      }
      return ret_pc;
    }
  }
  cpu.sr[CSR_MTVAL] = tval;
  cpu.sr[CSR_MEPC] = epc;
  cpu.sr[CSR_MCAUSE] = NO;
  csr_t reg = {.val = cpu.sr[CSR_MSTATUS]};
  reg.mstatus.mpp = cpu.priv;
  reg.mstatus.mpie = reg.mstatus.mie;
  reg.mstatus.mie = 0;
  cpu.sr[CSR_MSTATUS] = reg.val;

  cpu.last_inst_priv = cpu.priv;
  cpu.raise_intr = NO;
  cpu.priv = PRV_M;
  soft_tlb_flush();
  {
    word_t mtvec = cpu.sr[CSR_MTVEC];
    word_t base  = mtvec & ~(word_t)0x3;
    word_t mode  = mtvec & 0x3;
    bool   is_int = (NO & ((word_t)1 << (XLEN - 1))) != 0;
    /* Mode 01 = Vectored: base + 4*cause for interrupts; base for exceptions.
     * Mode 00 = Direct: always base.  Reserved modes coerced at CSR-write time. */
    if (mode == 1 && is_int) {
      ret_pc = base + (word_t)((NO & ~((word_t)1 << (XLEN - 1))) * 4);
    } else {
      ret_pc = base;
    }
  }
  return ret_pc;
}

#if !defined(CONFIG_TARGET_SHARE)
// Helper: check if an interrupt (given its MIP bit position) can be taken,
// considering delegation, privilege level, and global interrupt enables.
static inline bool can_take_interrupt(int bit, csr_t reg_mstatus)
{
  word_t deleg = cpu.sr[CSR_MIDELEG] & ((word_t)1 << bit);
  if (deleg)
    return (cpu.priv < PRV_S) ||
           (cpu.priv == PRV_S && reg_mstatus.mstatus.sie);
  else
    return (cpu.priv < PRV_M) ||
           (cpu.priv == PRV_M && reg_mstatus.mstatus.mie);
}
#endif

word_t isa_query_intr()
{
#if defined(CONFIG_TARGET_SHARE)
  // In reference model mode, all interrupts are injected externally
  // via difftest_raise_intr(). Do not auto-detect from MIP bits.
  return INTR_EMPTY;
#else
  csr_t reg_mstatus = {.val = cpu.sr[CSR_MSTATUS]};
  word_t mip = cpu.sr[CSR_MIP];
  word_t mie = cpu.sr[CSR_MIE];
  word_t pending = mip & mie;

  if (pending == 0)
    return INTR_EMPTY;

  // RISC-V interrupt priority (highest first): MEI > MSI > MTI > SEI > SSI > STI

  // --- Machine External Interrupt (MEIP, bit 11) ---
  if (pending & (1u << 11))
  {
    if (can_take_interrupt(11, reg_mstatus))
      return MCA_MAC_EXT_INT;
  }

  // --- Machine Software Interrupt (MSIP, bit 3) ---
  if (pending & (1u << 3))
  {
    if (can_take_interrupt(3, reg_mstatus))
      return MCA_MAC_SOF_INT;
  }

  // --- Machine Timer Interrupt (MTIP, bit 7) ---
  if (pending & (1u << 7))
  {
    if (can_take_interrupt(7, reg_mstatus))
      return MCA_MAC_TIM_INT;
  }

  // --- Supervisor External Interrupt (SEIP, bit 9) ---
  if (pending & (1u << 9))
  {
    if (can_take_interrupt(9, reg_mstatus))
      return MCA_SUP_EXT_INT;
  }

  // --- Supervisor Software Interrupt (SSIP, bit 1) ---
  if (pending & (1u << 1))
  {
    if (can_take_interrupt(1, reg_mstatus))
      return MCA_SUP_SOF_INT;
  }

  // --- Supervisor Timer Interrupt (STIP, bit 5) ---
  if (pending & (1u << 5))
  {
    if (can_take_interrupt(5, reg_mstatus))
      return MCA_SUP_TIM_INT;
  }

  return INTR_EMPTY;
#endif
}

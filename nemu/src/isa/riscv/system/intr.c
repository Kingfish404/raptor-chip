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
#include <cpu/multidiff.h>
#include <memory/tlb.h>

#if defined(CONFIG_ISA64)
// for riscv64
#define IRQ_TIMER 0x8000000000000007
#else
// for riscv32
#define IRQ_TIMER 0x80000007
#endif

extern NEMU_TLS word_t g_vaddr;
NEMU_TLS paddr_t riscv_h_fault_gpa;
NEMU_TLS bool riscv_h_fault_ptw;
NEMU_TLS bool riscv_h_fault_write;
NEMU_TLS bool riscv_h_explicit_trap;

word_t isa_raise_intr(word_t NO, vaddr_t epc)
{
  /* Traps and xRETs rewrite mstatus (MPP/SPP/MIE/...); force the CSR commit
   * tail so the sstatus/SD/sie views are re-derived this instruction. */
  cpu.csr_dirty = true;
  if (!(NO & MCA_INTR_BIT)) cpu.instruction_trapped = true;
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
    case MCA_VIRT_INS:
      // RV32 fetch may retain the following parcel in cpu.inst. Illegal
      // compressed instructions report only their own 16-bit encoding.
      tval = (cpu.inst & 3) == 3 ? cpu.inst : (cpu.inst & 0xffff);
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
    case MCA_ENV_CAL_VSMO:
    case MCA_ENV_CAL_MMO:
      tval = 0;
      break;
    case MCA_INS_PAG_FAU:
    case MCA_INS_GUEST_PAG_FAU:
      /* epc identifies the instruction; a straddling instruction can fault
       * on the second halfword, whose VA is retained by vaddr_ifetch. */
      tval = g_vaddr;
      break;
    case MCA_LOA_PAG_FAU:
    case MCA_STO_PAG_FAU:
    case MCA_LOA_GUEST_PAG_FAU:
    case MCA_STO_GUEST_PAG_FAU:
      tval = g_vaddr;
      break;
    default:
      tval = 0;
      break;
    }
  }
  word_t ret_pc = 0;
  const bool is_interrupt = (NO & MCA_INTR_BIT) != 0;
  const word_t cause = NO & ~MCA_INTR_BIT;
  const word_t delegation = cpu.sr[is_interrupt ? CSR_MIDELEG : CSR_MEDELEG] |
      (is_interrupt ? (word_t)riscv_virtual_irq_mask() : 0);
  if (cpu.priv <= PRV_S)
  {
    // Interrupts consult only mideleg, exceptions only medeleg. Never shift
    // by the interrupt flag or by an unrepresentable delegation bit number.
    if (cause < XLEN && ((delegation >> cause) & 1))
    {
      if (cpu.virt && riscv_h_gstage_preview_enabled() &&
          ((cpu.sr[is_interrupt ? CSR_HIDELEG : CSR_HEDELEG] >> cause) & 1))
      {
        word_t vs_cause = is_interrupt &&
            (((word_t)1 << cause) & (word_t)riscv_virtual_irq_mask())
            ? MCA_INTR_BIT | (cause - 1) : NO;
        cpu.sr[CSR_VSTVAL] = tval;
        cpu.sr[CSR_VSEPC] = epc;
        cpu.sr[CSR_VSCAUSE] = vs_cause;
        csr_t reg_v = {.val = cpu.sr[CSR_VSSTATUS]};
        reg_v.mstatus.spp = cpu.priv;
        reg_v.mstatus.spie = reg_v.mstatus.sie;
        reg_v.mstatus.sie = 0;
        cpu.sr[CSR_VSSTATUS] = reg_v.val;
        cpu.last_inst_priv = cpu.priv;
        cpu.priv = PRV_S;
        soft_tlb_flush();
        word_t vstvec = cpu.sr[CSR_VSTVEC];
        word_t base = vstvec & ~(word_t)0x3;
        return is_interrupt && (vstvec & 0x3) == 1
            ? base + (vs_cause & ~MCA_INTR_BIT) * 4 : base;
      }
      // printf("NO: %x, (NO & (1 << (XLEN - 1))): %x, "
      //        "(1 << (NO & ~(1 << (XLEN - 1)))): %x\n",
      //        NO, (NO & (1 << (XLEN - 1))), (1 << (NO & ~(1 << (XLEN - 1)))));
      cpu.sr[CSR_STVAL] = tval;
      if (riscv_h_gstage_preview_enabled())
      {
        bool guest_fault = NO == MCA_INS_GUEST_PAG_FAU ||
            NO == MCA_LOA_GUEST_PAG_FAU || NO == MCA_STO_GUEST_PAG_FAU;
        cpu.sr[CSR_HTVAL] = guest_fault ? riscv_h_fault_gpa >> 2 : 0;
        cpu.sr[CSR_HTINST] = guest_fault && riscv_h_fault_ptw ?
            (riscv_h_fault_write ? 0x3020 : 0x3000) : 0;
        word_t hstatus = cpu.sr[CSR_HSTATUS] & ~((word_t)3 << 6);
        bool guest_address = cpu.virt &&
            (NO == MCA_BREAK_POINT || NO == MCA_INS_PAG_FAU || NO == MCA_LOA_PAG_FAU ||
             NO == MCA_STO_PAG_FAU || guest_fault ||
             NO == MCA_INS_ACC_FAU || NO == MCA_LOA_ACC_FAU ||
             NO == MCA_STO_ACC_FAU || NO == MCA_INS_ADD_MIS ||
             NO == MCA_LOA_ADD_MIS || NO == MCA_STO_ADD_MIS);
        if (guest_address || riscv_h_explicit_trap) hstatus |= (word_t)1 << 6;
        if (cpu.virt) hstatus |= (word_t)1 << 7;
        if (cpu.virt)
        {
          hstatus &= ~((word_t)1 << 8);
          if (cpu.priv == PRV_S) hstatus |= (word_t)1 << 8;
        }
        cpu.sr[CSR_HSTATUS] = hstatus;
      }
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
      cpu.virt = false;
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
      return riscv_legalize_pc(ret_pc);
    }
  }
  cpu.sr[CSR_MTVAL] = tval;
  if (riscv_h_gstage_preview_enabled())
  {
    bool guest_fault = NO == MCA_INS_GUEST_PAG_FAU ||
        NO == MCA_LOA_GUEST_PAG_FAU || NO == MCA_STO_GUEST_PAG_FAU;
    cpu.sr[CSR_MTVAL2] = guest_fault ? riscv_h_fault_gpa >> 2 : 0;
    cpu.sr[CSR_MTINST] = guest_fault && riscv_h_fault_ptw ?
        (riscv_h_fault_write ? 0x3020 : 0x3000) : 0;
  }
  cpu.sr[CSR_MEPC] = epc;
  cpu.sr[CSR_MCAUSE] = NO;
  csr_t reg = {.val = cpu.sr[CSR_MSTATUS]};
  reg.mstatus.mpp = cpu.priv;
  reg.mstatus.mpie = reg.mstatus.mie;
  reg.mstatus.mie = 0;
  if (riscv_h_gstage_preview_enabled())
  {
    reg.val &= ~(word_t)(UINT64_C(3) << 38);
    if (cpu.virt) reg.val |= (word_t)(UINT64_C(1) << 39);
    bool guest_address = cpu.virt &&
        (NO == MCA_BREAK_POINT || NO == MCA_INS_PAG_FAU || NO == MCA_LOA_PAG_FAU ||
         NO == MCA_STO_PAG_FAU || NO == MCA_INS_GUEST_PAG_FAU ||
         NO == MCA_LOA_GUEST_PAG_FAU || NO == MCA_STO_GUEST_PAG_FAU ||
         NO == MCA_INS_ACC_FAU || NO == MCA_LOA_ACC_FAU ||
         NO == MCA_STO_ACC_FAU || NO == MCA_INS_ADD_MIS ||
         NO == MCA_LOA_ADD_MIS || NO == MCA_STO_ADD_MIS);
    guest_address = guest_address || (riscv_data_virtual_mode() &&
        (NO == MCA_LOA_PAG_FAU || NO == MCA_STO_PAG_FAU ||
         NO == MCA_LOA_GUEST_PAG_FAU || NO == MCA_STO_GUEST_PAG_FAU ||
         NO == MCA_LOA_ACC_FAU || NO == MCA_STO_ACC_FAU ||
         NO == MCA_LOA_ADD_MIS || NO == MCA_STO_ADD_MIS));
    if (guest_address || riscv_h_explicit_trap)
      reg.val |= (word_t)(UINT64_C(1) << 38);
  }
  cpu.sr[CSR_MSTATUS] = reg.val;

  cpu.last_inst_priv = cpu.priv;
  cpu.raise_intr = NO;
  cpu.priv = PRV_M;
  cpu.virt = false;
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
  return riscv_legalize_pc(ret_pc);
}

#if !defined(CONFIG_TARGET_SHARE) || defined(NEMU_HAS_REPLAY)
// Helper: check if an interrupt (given its MIP bit position) can be taken,
// considering delegation, privilege level, and global interrupt enables.
static inline bool can_take_interrupt(int bit, csr_t reg_mstatus)
{
  word_t irq_bit = (word_t)1 << bit;
  if (irq_bit & (word_t)riscv_virtual_irq_mask())
  {
    if (cpu.sr[CSR_HIDELEG] & irq_bit)
      return cpu.virt && (cpu.priv < PRV_S ||
                          (cpu.priv == PRV_S && (cpu.sr[CSR_VSSTATUS] & 0x2)));
    return cpu.virt || cpu.priv < PRV_S ||
           (cpu.priv == PRV_S && reg_mstatus.mstatus.sie);
  }
  word_t deleg = cpu.sr[CSR_MIDELEG] & irq_bit;
  if (deleg)
    return cpu.virt || (cpu.priv < PRV_S) ||
           (cpu.priv == PRV_S && reg_mstatus.mstatus.sie);
  else
    return (cpu.priv < PRV_M) ||
           (cpu.priv == PRV_M && reg_mstatus.mstatus.mie);
}
#endif

word_t isa_query_intr()
{
#if defined(CONFIG_TARGET_SHARE) && !defined(NEMU_HAS_REPLAY)
  return INTR_EMPTY;
#else
#ifdef CONFIG_TARGET_SHARE
  if (!nemu_md_interrupts) return INTR_EMPTY;
#endif
  csr_t reg_mstatus = {.val = cpu.sr[CSR_MSTATUS]};
  word_t mip = riscv_mip_value();
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

  if (pending & (1u << 10))
  {
    if (can_take_interrupt(10, reg_mstatus))
      return MCA_VSUP_EXT_INT;
  }

  if (pending & (1u << 2))
  {
    if (can_take_interrupt(2, reg_mstatus))
      return MCA_VSUP_SOF_INT;
  }

  if (pending & (1u << 6))
  {
    if (can_take_interrupt(6, reg_mstatus))
      return MCA_VSUP_TIM_INT;
  }

  if (riscv_sscofpmf_enabled() && (pending & (1u << 13)) &&
      can_take_interrupt(13, reg_mstatus))
    return MCA_COU_OVE_INT;

  return INTR_EMPTY;
#endif
}

/* rvmodel_macros.h: Raptor Chip RVA23S64 DUT macros for ACT4 + Sail 0.16 */
/* SPDX-License-Identifier: Apache-2.0 */

#ifndef _COMPLIANCE_MODEL_H
#define _COMPLIANCE_MODEL_H

#define RVMODEL_DATA_SECTION

#define STANDARD_SM_SUPPORTED

/* ===== STARTUP ===== */

#define RVMODEL_BOOT

#define RVMODEL_ACCESS_FAULT_ADDRESS 0x00000000

/* ===== TERMINATION ===== */

/* Breakpoints inside tests are architectural traps. Run NPC with
   --trap-on-ebreak; only the SiFive test finisher terminates a test. */
#define RVMODEL_HALT_PASS \
  li a0, 0; li t0, 0x00100000; li t1, 0x5555; sw t1, 0(t0); \
  fence iorw, iorw; self_loop_pass: j self_loop_pass;

#define RVMODEL_HALT_FAIL \
  li a0, 1; li t0, 0x00100000; li t1, 0x3333; sw t1, 0(t0); \
  fence iorw, iorw; self_loop_fail: j self_loop_fail;

/* ===== IO ===== */

/* Raptor has a 16550-compatible UART at 0x10000000 */
.EQU UART_BASE_ADDR, 0x10000000
.EQU UART_THR, (UART_BASE_ADDR + 0)
.EQU UART_LSR, (UART_BASE_ADDR + 5)

#define RVMODEL_IO_INIT(_R1, _R2, _R3)

#define RVMODEL_IO_WRITE_STR(_R1, _R2, _R3, _STR_PTR)               \
1:                           ;                                       \
  lbu _R1, 0(_STR_PTR)        ;/* Load byte */                       \
  beqz _R1, 3f                ;/* Exit if null */                    \
2:                           ;                                       \
  li _R2, UART_LSR             ;                                     \
  4:                           ;                                     \
    lbu _R3, 0(_R2)            ;                                     \
    andi _R3, _R3, 0x20        ;/* Check THR Empty */                \
    beqz _R3, 4b               ;                                     \
  li _R2, UART_THR             ;                                     \
  sb _R1, 0(_R2)               ;                                     \
  addi _STR_PTR, _STR_PTR, 1   ;/* Next char */                     \
  j 1b                         ;/* Loop */                           \
3:

/* ===== Machine Timer & Software Interrupts (CLINT @ 0x02000000) ===== */

#define RVMODEL_MSIP_ADDRESS     0x02000000
#define RVMODEL_MTIMECMP_ADDRESS 0x02004000
#define RVMODEL_MTIME_ADDRESS    0x0200bff8

#define RVMODEL_INTERRUPT_LATENCY    20
#define RVMODEL_TIMER_INT_SOON_DELAY 500

/* ===== Machine External Interrupts (PLIC @ 0x0c000000, source 2 -> ctx0) ===== */

#define RAPT_PLIC_PRIO2_ADDR   0x0c000008
#define RAPT_PLIC_PEND_ADDR    0x0c001000
#define RAPT_PLIC_MENABLE_ADDR 0x0c002000
#define RAPT_PLIC_MTHRESH_ADDR 0x0c200000
#define RAPT_PLIC_MCLAIM_ADDR  0x0c200004

/* S/U-mode flavors use T-SBI physical MMIO helpers (a0/a1/a2 are caller-saved). */
#define RVMODEL_SET_MEXT_INT(_R1, _R2) \
  li a1, RAPT_PLIC_PRIO2_ADDR;   li a2, 1; RVTEST_TSBI_SW; \
  li a1, RAPT_PLIC_MENABLE_ADDR; li a2, 4; RVTEST_TSBI_SW; \
  li a1, RAPT_PLIC_MTHRESH_ADDR; li a2, 0; RVTEST_TSBI_SW; \
  li a1, RAPT_PLIC_PEND_ADDR;    li a2, 4; RVTEST_TSBI_SW;

#define RVMODEL_CLR_MEXT_INT(_R1, _R2) \
  li a1, RAPT_PLIC_MCLAIM_ADDR;  RVTEST_TSBI_LW; \
  li a1, RAPT_PLIC_MCLAIM_ADDR;  li a2, 2; RVTEST_TSBI_SW; \
1: RVTEST_TSBI_CSR_READ(CSR_MIP); srli a0, a0, 11; andi a0, a0, 1; bnez a0, 1b;

/* M-mode flavors touch only _R1 and _R2 directly. */
#define RVMODEL_SET_MEXT_INT_M(_R1, _R2) \
  li _R2, RAPT_PLIC_PRIO2_ADDR;   li _R1, 1; sw _R1, 0(_R2); \
  li _R2, RAPT_PLIC_MENABLE_ADDR; li _R1, 4; sw _R1, 0(_R2); \
  li _R2, RAPT_PLIC_MTHRESH_ADDR;            sw zero, 0(_R2); \
  li _R2, RAPT_PLIC_PEND_ADDR;    li _R1, 4; sw _R1, 0(_R2);

#define RVMODEL_CLR_MEXT_INT_M(_R1, _R2) \
  li _R2, RAPT_PLIC_MCLAIM_ADDR; lw _R1, 0(_R2); \
  li _R1, 2; sw _R1, 0(_R2); \
  li _R2, 0x800; \
1: csrr _R1, mip; and _R1, _R1, _R2; bnez _R1, 1b;

/* Supervisor interrupts: leave RVMODEL_SET/CLR_{SEXT,SSW}_INT undefined so
   ACT4 uses mip.SEIP / mip.SSIP via T-SBI on DUT and sail_macros.h on Sail. */

/* ===== Sscofpmf (mhpmcounter3 / mhpmevent3, selector 0x1 = retired FENCE) ===== */

#define RVMODEL_HPM_COUNTER   3
#define RVMODEL_MHPMEVENT_VAL 0x1
#define RVMODEL_MHPMEVENT_CODE(_R1, _R2) \
  fence

#endif /* _COMPLIANCE_MODEL_H */

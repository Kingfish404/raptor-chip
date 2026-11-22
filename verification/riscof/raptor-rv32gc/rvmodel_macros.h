/* rvmodel_macros.h: Raptor Chip RV32GC DUT macros for ACT4 + Sail 0.16 */
/* SPDX-License-Identifier: Apache-2.0 */

#ifndef _COMPLIANCE_MODEL_H
#define _COMPLIANCE_MODEL_H

#define RVMODEL_DATA_SECTION

#define STANDARD_SM_SUPPORTED

/* Binutils >= 2.38 requires +zifencei for 'fence.i', which ACT4 base
   -march=rv32i_zicsr priv tests omit. Emit the exact fence.i encoding. */
#define RVMODEL_FENCEI .word 0x0000100f

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

#define RVMODEL_SET_MEXT_INT(_R1, _R2) \
  li _R2, RAPT_PLIC_PRIO2_ADDR;   li _R1, 1; sw _R1, 0(_R2); \
  li _R2, RAPT_PLIC_MENABLE_ADDR; li _R1, 4; sw _R1, 0(_R2); \
  li _R2, RAPT_PLIC_MTHRESH_ADDR;            sw zero, 0(_R2); \
  li _R2, RAPT_PLIC_PEND_ADDR;    li _R1, 4; sw _R1, 0(_R2);

#define RVMODEL_CLR_MEXT_INT(_R1, _R2) \
  li _R2, RAPT_PLIC_MCLAIM_ADDR; lw _R1, 0(_R2); \
  li _R1, 2; sw _R1, 0(_R2); \
  li _R2, 0x800; \
1: csrr _R1, mip; and _R1, _R1, _R2; bnez _R1, 1b;

#define RVMODEL_SET_MSW_INT(_R1, _R2) \
  li _R2, RVMODEL_MSIP_ADDRESS; li _R1, 1; sw _R1, 0(_R2);

#define RVMODEL_CLR_MSW_INT(_R1, _R2) \
  li _R2, RVMODEL_MSIP_ADDRESS; sw zero, 0(_R2);

/* ===== Supervisor Interrupts ===== */

#define RVMODEL_SET_SEXT_INT(_R1, _R2)
#define RVMODEL_CLR_SEXT_INT(_R1, _R2)
#define RVMODEL_SET_SSW_INT(_R1, _R2)
#define RVMODEL_CLR_SSW_INT(_R1, _R2)

#endif /* _COMPLIANCE_MODEL_H */

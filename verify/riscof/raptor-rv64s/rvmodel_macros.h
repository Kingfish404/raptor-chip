/* rvmodel_macros.h: Raptor Chip DUT-specific macros for ACT4 */
/* SPDX-License-Identifier: Apache-2.0 */

#ifndef _COMPLIANCE_MODEL_H
#define _COMPLIANCE_MODEL_H

#define RVMODEL_DATA_SECTION

/* ===== STARTUP ===== */

#define RVMODEL_BOOT

#define RVMODEL_ACCESS_FAULT_ADDRESS 0x00000000

/* ===== TERMINATION ===== */

/* Breakpoints inside tests are architectural traps. Run NPC with
   --trap-on-ebreak; only the finisher terminates a test. */
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

/* ===== Machine Timer ===== */

/* NPC CLINT addresses from hdl/include/npc/rapt_soc.svh. */
#define RVMODEL_MTIME_ADDRESS    0x0200bff8
#define RVMODEL_MTIMECMP_ADDRESS 0x02004000

#define RVMODEL_INTERRUPT_LATENCY 10
#define RVMODEL_TIMER_INT_SOON_DELAY 100

/* ===== Machine Interrupts ===== */

#define RVMODEL_SET_MEXT_INT(_R1, _R2)
#define RVMODEL_CLR_MEXT_INT(_R1, _R2)
#define RVMODEL_SET_MSW_INT(_R1, _R2)
#define RVMODEL_CLR_MSW_INT(_R1, _R2)

/* ===== Supervisor Interrupts ===== */

#define RVMODEL_SET_SEXT_INT(_R1, _R2)
#define RVMODEL_CLR_SEXT_INT(_R1, _R2)
#define RVMODEL_SET_SSW_INT(_R1, _R2)
#define RVMODEL_CLR_SSW_INT(_R1, _R2)

#endif /* _COMPLIANCE_MODEL_H */

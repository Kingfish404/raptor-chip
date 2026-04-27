/* model_test.h : Raptor Chip RISCOF DUT compliance macros.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Halt strategy: write the sifive,test "finisher" MMIO device at 0x100000
 * with pass code 0x5555 (low 16 bits) to terminate the simulation cleanly.
 * This avoids using `ebreak` as a halt signal, so that tests which
 * deliberately execute `ebreak` (e.g. rv32i_m/privilege/src/ebreak.S,
 * rv32i_m/C/src/cebreak-01.S) can still flow through the M-mode trap
 * handler and reach the signature-write / halt sequence.
 *
 * Signature bytes are dumped by the simulator via --sig=<begin>-<end>:<path>;
 * the Raptor DUT plugin extracts begin_signature / end_signature symbol
 * addresses from the ELF and passes them to the simulator.
 */

#ifndef _COMPLIANCE_MODEL_H
#define _COMPLIANCE_MODEL_H

#define ALIGNMENT 2

#define RVMODEL_DATA_SECTION                 \
  .align 8; .global begin_regstate;          \
  begin_regstate:                            \
  .word 128;                                 \
  .align 8; .global end_regstate;            \
  end_regstate:                              \
  .word 4;

#define RVMODEL_DATA_BEGIN                   \
  RVMODEL_DATA_SECTION                       \
  .align 4; .global begin_signature;         \
  begin_signature:

#define RVMODEL_DATA_END                     \
  .align 4; .global end_signature;           \
  end_signature:

/* Default-trap vector: catches unexpected exceptions and halts with fail code.
 * Encode `csrw mtvec, x10` as .word to avoid requiring Zicsr at assembly.
 * boot_terminate writes the finisher-fail (0x3333) MMIO command; the
 * simulator halts synchronously on that write, so no explicit spin loop is
 * needed.  Keeping the sequence exactly 4 instructions makes rvtest_init
 * land at the same address as the sail reference (+0x20 boot footprint). */
#define RVMODEL_BOOT                         \
    la    x10, boot_terminate;               \
    .word 0x30551073;                        \
    j     boot_end;                          \
  boot_terminate:                            \
    li    t0, 0x100000;                      \
    li    t1, 0x3333;                        \
    sw    t1, 0(t0);                         \
  boot_end:

/* Halt via sifive,test finisher MMIO (pass = 0x5555). */
#define RVMODEL_HALT                         \
    li    t0, 0x100000;                      \
    li    t1, 0x5555;                        \
    sw    t1, 0(t0);                         \
  self_loop_halt:                            \
    j self_loop_halt;

/* IO / assertion macros: unused on this DUT (compliance tests run in batch). */
#define RVMODEL_IO_INIT
#define RVMODEL_IO_WRITE_STR(_R, _STR)
#define RVMODEL_IO_CHECK()
#define RVMODEL_IO_ASSERT_GPR_EQ(_S, _R, _I)
#define RVMODEL_IO_ASSERT_SFPR_EQ(_F, _R, _I)
#define RVMODEL_IO_ASSERT_DFPR_EQ(_D, _R, _I)

/* PMP capability: 16 entries, grain = 4 bytes (G=0). */
#define RVMODEL_NUM_PMPS  16
#define RVMODEL_PMP_GRAIN 0

/* Interrupt set/clear hooks - CLINT mtime-based, unused for arch-tests. */
#define RVMODEL_SET_MSW_INT
#define RVMODEL_CLEAR_MSW_INT
#define RVMODEL_CLEAR_MTIMER_INT
#define RVMODEL_CLEAR_MEXT_INT
#define RVMODEL_SET_MTIMER_INT
#define RVMODEL_SET_MEXT_INT
#define RVMODEL_CLR_MSW_INT
#define RVMODEL_CLR_MTIMER_INT
#define RVMODEL_CLR_MEXT_INT

#endif /* _COMPLIANCE_MODEL_H */

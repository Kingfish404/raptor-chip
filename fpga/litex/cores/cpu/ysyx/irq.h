#ifndef __IRQ_H
#define __IRQ_H

#ifdef __cplusplus
extern "C" {
#endif

#include <system.h>
#include <generated/csr.h>
#include <generated/soc.h>

/*
 * Raptor IRQ interface for LiteX BIOS.
 *
 * The BIOS operates in polling mode — irq mask/pending use software-only
 * stubs so the BIOS never issues PLIC MMIO (which would require a real
 * PLIC IP on the bus).  irq_setie/irq_getie use the standard mstatus CSR.
 *
 * When booting Linux, OpenSBI provides its own PLIC driver and does not
 * use these functions.
 *
 * PLIC constants are still defined because isr.c references them for
 * plic_init() / isr() even when the actual mask/pending helpers are no-ops.
 */

#define PLIC_BASE    0x0c000000L
#define PLIC_PENDING 0x0c001000L
#define PLIC_ENABLED 0x0c002000L
#define PLIC_THRSHLD 0x0c200000L
#define PLIC_CLAIM   0x0c200004L

#define PLIC_EXT_IRQ_BASE 0

static inline unsigned int irq_getie(void)
{
	return (csrr(mstatus) & CSR_MSTATUS_MIE) != 0;
}

static inline void irq_setie(unsigned int ie)
{
	if (ie) csrs(mstatus, CSR_MSTATUS_MIE);
	else    csrc(mstatus, CSR_MSTATUS_MIE);
}

/* Polling mode: mask/pending are no-ops; UART uses polled I/O. */
static inline unsigned int irq_getmask(void)
{
	return 0;
}

static inline void irq_setmask(unsigned int mask)
{
	(void)mask;
}

static inline unsigned int irq_pending(void)
{
	return 0;
}

#ifdef __cplusplus
}
#endif

#endif /* __IRQ_H */

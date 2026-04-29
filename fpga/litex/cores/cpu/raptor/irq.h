#ifndef __IRQ_H
#define __IRQ_H

#ifdef __cplusplus
extern "C" {
#endif

#include <system.h>
#include <generated/csr.h>
#include <generated/soc.h>

/*
 * Raptor connects all LiteX peripheral IRQs onto the standard RISC-V
 * external-interrupt line (mip[MEIP] / mie[MEIE], bit 11). LiteX BIOS,
 * however, expects a VexRiscv-style per-peripheral IRQ controller and
 * uses irq_setmask((1 << UART_INTERRUPT)) etc. — on standard RISC-V that
 * would write mie[0] (USIE / reserved) and clear MEIE, preventing every
 * delivered interrupt and deadlocking the BIOS UART ring buffer.
 *
 * Workaround: keep mie[MEIE] set whenever any peripheral mask bit is on,
 * and emulate the per-peripheral mask in software. We use the M-mode
 * `mscratch` CSR as a cross-TU process-global shadow. Reset clears
 * mscratch via crt_init.
 *
 * Note: irq_pending() reports the shadow mask whenever MEIP is asserted
 * (single aggregated external line — we have no per-peripheral pending),
 * which matches what the BIOS dispatcher needs ((pending & mask) != 0).
 */

#define _RAPT_MEIE  (1u << 11)

static inline unsigned int irq_getie(void)
{
	return (csrr(mstatus) & CSR_MSTATUS_MIE) != 0;
}

static inline void irq_setie(unsigned int ie)
{
	if (ie) csrs(mstatus, CSR_MSTATUS_MIE);
	else    csrc(mstatus, CSR_MSTATUS_MIE);
}

static inline unsigned int irq_getmask(void)
{
	unsigned int v;
	asm volatile ("csrr %0, mscratch" : "=r"(v));
	return v;
}

static inline void irq_setmask(unsigned int mask)
{
	asm volatile ("csrw mscratch, %0" :: "r"(mask));
	if (mask) csrs(mie, _RAPT_MEIE);
	else      csrc(mie, _RAPT_MEIE);
}

static inline unsigned int irq_pending(void)
{
	unsigned int mip = csrr(mip);
	unsigned int shadow;
	asm volatile ("csrr %0, mscratch" : "=r"(shadow));
	return (mip & _RAPT_MEIE) ? shadow : 0;
}

#ifdef __cplusplus
}
#endif

#endif /* __IRQ_H */

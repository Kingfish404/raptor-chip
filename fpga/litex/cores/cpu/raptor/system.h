#ifndef __SYSTEM_H
#define __SYSTEM_H

#ifdef __cplusplus
extern "C"
{
#endif

#include <csr-defs.h>
#include <generated/soc.h>

  __attribute__((unused)) static void flush_cpu_icache(void)
  {
#if defined(CONFIG_CPU_HAS_ICACHE)
    asm volatile("fence.i" ::: "memory");
#endif
  }

  __attribute__((unused)) static void flush_cpu_dcache(void)
  {
#if defined(CONFIG_CPU_HAS_DCACHE)
    asm volatile("fence" ::: "memory");
#endif
  }

  void flush_l2_cache(void);

  void busy_wait(unsigned int ms);
  void busy_wait_us(unsigned int us);

  /*
   * Last synchronous exception captured by `trap_entry` in crt0.S.
   *
   * The asm fast path in trap_entry stashes mcause/mepc/mtval here and
   * advances mepc past the offending instruction so the BIOS prompt is
   * recoverable after a stray access (e.g. `mem_read 0xdeadbeef`).
   * `count` is post-incremented; user code can latch a baseline value
   * before issuing a probe and check for a delta to detect that a fault
   * occurred. Layout MUST stay in sync with the offsets in crt0.S.
   */
  struct rapt_last_exc
  {
    unsigned long mcause;
    unsigned long mepc;
    unsigned long mtval;
    unsigned long count;
  };
  extern struct rapt_last_exc rapt_last_exc;

/*
 * Override LiteX's csr_write_simple / csr_read_simple to fully serialize
 * every MMIO access. Required because Raptor's LSU does not enforce MMIO
 * ordering: the STQ buffers stores and the load pipe may issue MMIO loads
 * past in-flight MMIO stores AND past prior MMIO loads in program order
 * (RVWMO permits both for distinct addresses).
 *
 * Concrete failure modes observed on Tang Mega 138K Pro (2026-04-27):
 *  - LiteUART RX FIFO pops only on `ev_pending` W1C (rx_fifo_rx_we=False).
 *    Sequence in uart_isr:
 *        c = uart_rxtx_read();              // load FIFO head
 *        uart_ev_pending_write(UART_EV_RX); // store -> pops FIFO
 *        ... uart_rxempty_read() ...        // load
 *    Without fences, the store may issue before the rxtx load drains
 *    -> load returns the post-pop head -> bytes silently dropped, causing
 *       'serialboot' calibration corruption ('E'/'b'/CRC errors) and
 *       paste duplication in the BIOS shell.
 *  - mem_speed Write 6.3MiB/s anomaly was the same class of bug.
 *
 * `fence iorw,iorw` is the heaviest RVWMO fence: it orders all prior MMIO
 * loads/stores before all subsequent MMIO loads/stores. Bracketing every
 * CSR access with a fence guarantees strict program order for MMIO,
 * matching what most simple cores enforce in HW.
 *
 * TODO(rtl): Make Raptor LSU treat io_region (0xC000_0000+) accesses as
 * strongly ordered (no buffering, no load reorder past prior IO ops),
 * then drop these software fences. Tracked in repo memory.
 */
#ifndef __ASSEMBLER__
#include <stdint.h>
#ifndef MMPTR
#define MMPTR(a) (*((volatile uint32_t *)(a)))
#endif

#define CSR_ACCESSORS_DEFINED
  static inline void csr_write_simple(unsigned long v, unsigned long a)
  {
    asm volatile("fence iorw,iorw" ::: "memory");
    MMPTR(a) = v;
    asm volatile("fence iorw,iorw" ::: "memory");
  }

  static inline unsigned long csr_read_simple(unsigned long a)
  {
    unsigned long r;
    asm volatile("fence iorw,iorw" ::: "memory");
    r = MMPTR(a);
    asm volatile("fence iorw,iorw" ::: "memory");
    return r;
  }
/* Pull in min/max/cdelay etc. (hw/common.h's inner block is skipped because
 * CSR_ACCESSORS_DEFINED is now set above). */
#include <hw/common.h>
#endif

#define csrr(reg) ({ unsigned long __tmp; \
  asm volatile ("csrr %0, " #reg : "=r"(__tmp)); \
  __tmp; })

#define csrw(reg, val) ({ \
  if (__builtin_constant_p(val) && (unsigned long)(val) < 32) \
	asm volatile ("csrw " #reg ", %0" :: "i"(val)); \
  else \
	asm volatile ("csrw " #reg ", %0" :: "r"(val)); })

#define csrs(reg, bit) ({ \
  if (__builtin_constant_p(bit) && (unsigned long)(bit) < 32) \
	asm volatile ("csrrs x0, " #reg ", %0" :: "i"(bit)); \
  else \
	asm volatile ("csrrs x0, " #reg ", %0" :: "r"(bit)); })

#define csrc(reg, bit) ({ \
  if (__builtin_constant_p(bit) && (unsigned long)(bit) < 32) \
	asm volatile ("csrrc x0, " #reg ", %0" :: "i"(bit)); \
  else \
	asm volatile ("csrrc x0, " #reg ", %0" :: "r"(bit)); })

#ifdef __cplusplus
}
#endif

#endif /* __SYSTEM_H */

#ifndef NEMU_CPU_MULTIDIFF_H
#define NEMU_CPU_MULTIDIFF_H

#include <common.h>
#include <difftest-def.h>
#include <difftest-multi.h>

bool nemu_md_active(void) __attribute__((weak));
bool nemu_md_guard(paddr_t address, int size, bool write, word_t data) __attribute__((weak));
bool nemu_md_dma_guard(paddr_t address, size_t size, bool write) __attribute__((weak));
void nemu_md_record(paddr_t address, int size, bool write, word_t data) __attribute__((weak));
bool nemu_md_instruction(uint32_t instruction) __attribute__((weak));
bool nemu_md_clint_active(void) __attribute__((weak));
bool nemu_md_plic_active(void) __attribute__((weak));
bool nemu_md_uart_active(void) __attribute__((weak));
bool nemu_md_rng_active(void) __attribute__((weak));
bool nemu_md_net_active(void) __attribute__((weak));
bool nemu_md_block_active(void) __attribute__((weak));
bool nemu_block_reset_state(void) __attribute__((weak));
const uint8_t *nemu_block_image(size_t *size) __attribute__((weak));
bool nemu_net_reset_state(void) __attribute__((weak));
bool nemu_net_input_consumed(void) __attribute__((weak));
bool nemu_rng_reset_state(void) __attribute__((weak));
bool nemu_uart_reset_state(void) __attribute__((weak));
bool nemu_plic_reset_state(void) __attribute__((weak));
void nemu_md_timer_update(void) __attribute__((weak));

static inline bool multidiff_active(void)
{
  return nemu_md_active && nemu_md_active();
}

static inline bool multidiff_clint_active(void)
{
  return nemu_md_clint_active && nemu_md_clint_active();
}

static inline bool multidiff_plic_active(void)
{
  return nemu_md_plic_active && nemu_md_plic_active();
}

static inline bool multidiff_uart_active(void)
{
  return nemu_md_uart_active && nemu_md_uart_active();
}

static inline bool multidiff_rng_active(void)
{
  return nemu_md_rng_active && nemu_md_rng_active();
}

static inline bool multidiff_net_active(void)
{
  return nemu_md_net_active && nemu_md_net_active();
}

static inline bool multidiff_block_active(void)
{
  return nemu_md_block_active && nemu_md_block_active();
}

#ifdef CONFIG_ISA_riscv
extern bool nemu_md_enabled;
extern bool nemu_md_interrupts;
extern bool nemu_md_clint;
extern bool nemu_md_plic;
extern bool nemu_md_uart;
extern bool nemu_md_rng;
extern bool nemu_md_net;
extern bool nemu_md_block;
extern bool nemu_md_tlb_retain;
extern unsigned nemu_md_harts;
bool nemu_md_clint_span(paddr_t address, int size, bool write);
bool nemu_md_plic_span(paddr_t address, int size);
bool nemu_md_uart_span(paddr_t address, int size);
bool nemu_md_rng_span(paddr_t address, int size);
bool nemu_md_net_span(paddr_t address, int size, bool write);
bool nemu_md_block_span(paddr_t address, int size);
extern NEMU_TLS NemuDiffFrame nemu_md_frame;
extern void (*nemu_md_invalidate)(paddr_t address, int size);
void nemu_md_capture(NemuDiffState *state);
void nemu_md_restore(const NemuDiffState *state);
void nemu_md_reset_frame(void);
uint64_t nemu_md_features(void);
void nemu_md_exec_one(void);
void pmp_hart_switch(void);
#endif

#ifdef NEMU_HAS_SMP
extern bool nemu_multidiff_requested;
void nemu_multidiff_init(const char *reference, size_t image_size);
bool nemu_multidiff_begin(void);
void nemu_multidiff_finish(void);
void nemu_multidiff_report(void);
#endif

#endif

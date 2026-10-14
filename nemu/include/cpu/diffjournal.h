#ifndef NEMU_DIFFJOURNAL_H
#define NEMU_DIFFJOURNAL_H

#include <common.h>

void nemu_journal_bus(bool entering) __attribute__((weak));
void nemu_journal_memory(paddr_t address, int size, bool write, word_t data) __attribute__((weak));
void nemu_journal_clock(uint64_t ticks, unsigned action) __attribute__((weak));
void nemu_journal_io(paddr_t address, int size, bool write, word_t data) __attribute__((weak));
void nemu_journal_start_worker(void) __attribute__((weak));
void nemu_journal_plic_source(unsigned source) __attribute__((weak));
void nemu_journal_inputs(uint64_t ticks) __attribute__((weak));
void nemu_journal_uart_irq(unsigned source) __attribute__((weak));
void nemu_journal_uart_tx(uint8_t byte, bool delivered) __attribute__((weak));
bool nemu_journal_dma_scope(void) __attribute__((weak));
bool nemu_journal_dma(paddr_t address, const void *bytes, size_t size, bool write, bool success) __attribute__((weak));
bool nemu_journal_rng_input(const void *bytes, size_t size, bool success) __attribute__((weak));
void nemu_journal_rng_irq(unsigned source) __attribute__((weak));
bool nemu_journal_net_rx(const void *bytes, size_t size) __attribute__((weak));
bool nemu_journal_net_tx(const void *bytes, size_t size) __attribute__((weak));
void nemu_journal_net_result(int64_t result, unsigned disposition) __attribute__((weak));
void nemu_journal_net_irq(unsigned source) __attribute__((weak));
bool nemu_journal_block_data(uint64_t offset, const void *bytes, size_t size, bool write) __attribute__((weak));
void nemu_journal_block_irq(unsigned source) __attribute__((weak));

#ifdef NEMU_HAS_SMP
extern const char *nemu_journal_path;
extern const char *nemu_plic_input_path;
extern const char *nemu_uart_input_path;
extern const char *nemu_rng_input_path;
extern const char *nemu_net_input_path;
extern bool nemu_net_script;
extern bool nemu_uart_stdin;
extern int nemu_journal_fd;
extern uint64_t nemu_journal_max_bytes;
extern uint64_t nemu_journal_progress_interval;
extern bool nemu_journal_limit_explicit;
static inline bool nemu_journal_requested(void)
{
  return nemu_journal_path || nemu_journal_fd >= 0;
}
void nemu_journal_init(void);
bool nemu_journal_begin(void);
void nemu_journal_end(void);
bool nemu_journal_interrupt(word_t cause);
void nemu_journal_close(void);
#endif

#endif

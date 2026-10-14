#ifndef NEMU_CPU_REPLAY_H
#define NEMU_CPU_REPLAY_H

#include <common.h>

#ifdef NEMU_HAS_REPLAY
void nemu_replay_lock(void) __attribute__((weak));
void nemu_replay_unlock(void) __attribute__((weak));
void nemu_replay_unwind(void) __attribute__((weak));
void nemu_replay_access(paddr_t address, int size, bool write, word_t data) __attribute__((weak));
word_t nemu_replay_clint(paddr_t address, int size, bool write, word_t data) __attribute__((weak));
word_t nemu_replay_plic(paddr_t address, int size, bool write, word_t data) __attribute__((weak));
word_t nemu_replay_uart(paddr_t address, int size, bool write, word_t data) __attribute__((weak));
word_t nemu_replay_rng(paddr_t address, int size, bool write, word_t data) __attribute__((weak));
word_t nemu_replay_net(paddr_t address, int size, bool write, word_t data) __attribute__((weak));
word_t nemu_replay_block(paddr_t address, int size, bool write, word_t data) __attribute__((weak));
#endif

#endif

#ifndef NEMU_CPU_SAMPLE_H
#define NEMU_CPU_SAMPLE_H

#include <common.h>

extern bool nemu_sample_enabled;
extern uint64_t nemu_sample_signature, nemu_sample_previous_signature;
void nemu_sample_configure(const char *points, const char *directory);
void nemu_sample_configure_bbv(const char *directory, uint64_t every);
void nemu_sample_bbv_boundary(void);
bool nemu_sample_tick(void);
void nemu_sample_retire(vaddr_t pc, uint32_t instruction, bool trapped);

#endif

#ifndef NEMU_RISCV_VECTOR_CONTROL_H
#define NEMU_RISCV_VECTOR_CONTROL_H

#include <isa-def.h>

void riscv_vector_reset(void);
bool riscv_vector_context_enabled(void);
bool riscv_vector_configure(uint32_t instruction);
bool riscv_vector_execute(uint32_t instruction);
word_t riscv_vector_memory(uint32_t instruction, bool store);
void riscv_vector_csr_write(uint16_t csr, word_t value);

#endif

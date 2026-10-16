#ifndef __MEMORY_TRAP_H__
#define __MEMORY_TRAP_H__

#include <common.h>
#include <setjmp.h>

extern NEMU_TLS jmp_buf *exec_jmp_override;
extern NEMU_TLS int cause;

void nemu_memory_longjmp(int value) __attribute__((noreturn));

#endif

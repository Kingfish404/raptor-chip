#ifndef ARCH_H__
#define ARCH_H__

#ifndef __USE_GNU
# define __USE_GNU
#endif

#if defined(__gnu_linux__)
#include <ucontext.h>
#elif defined(__APPLE__)
#include <sys/ucontext.h>
#include <sys/_types/_ucontext64.h>
#endif

struct Context {
  uintptr_t ksp;
  void *vm_head;
  ucontext_t uc;
  // skip the red zone of the stack frame, see the amd64 ABI manual for details
  uint8_t redzone[128];
};

#ifdef __x86_64__
#define GPR1 uc.uc_mcontext.gregs[REG_RDI]
#define GPR2 uc.uc_mcontext.gregs[REG_RSI]
#define GPR3 uc.uc_mcontext.gregs[REG_RDX]
#define GPR4 uc.uc_mcontext.gregs[REG_RCX]
#define GPRx uc.uc_mcontext.gregs[REG_RAX]
#elif __aarch64__ || __arm64__

#define REG_X0 0
#define REG_X1 1
#define REG_X2 2
#define REG_X3 3

#if defined(__gnu_linux__)
#define GPR1 uc.uc_mcontext.regs[REG_X0]
#define GPR2 uc.uc_mcontext.regs[REG_X1]
#define GPR3 uc.uc_mcontext.regs[REG_X2]
#define GPR4 uc.uc_mcontext.regs[REG_X3]
#define GPRx uc.uc_mcontext.regs[REG_X0]
#elif defined(__APPLE__)
#define GPR1 uc.uc_mcontext
#define GPR2 uc.uc_mcontext
#define GPR3 uc.uc_mcontext
#define GPR4 uc.uc_mcontext
#define GPRx uc.uc_mcontext
#endif
#endif

#undef __USE_GNU

#endif

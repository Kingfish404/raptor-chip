#include <stdint.h>

#ifdef __ISA_NATIVE__
#error can not support ISA=native
#endif

#define SYS_yield 1

extern int _syscall_(int type, uintptr_t a0, uintptr_t a1, uintptr_t a2);
// int _syscall_(int type, uintptr_t a0, uintptr_t a1, uintptr_t a2)
// {
//   register int ret = 0;
// #ifdef __riscv_64
//   asm volatile(
//       "mv a0, %1\n\t"
//       "mv a1, %2\n\t"
//       "mv a2, %3\n\t"
//       "mv a7, %4\n\t"
//       "ecall\n\t"
//       "mv %0, a0\n\t"
//       : "=r"(ret)
//       : "r"(a0), "r"(a1), "r"(a2), "r"(type)
//       : "a0", "a1", "a2", "a7");
// #elif __riscv
//   asm volatile(
//       "mv a0, %1\n\t"
//       "mv a1, %2\n\t"
//       "mv a2, %3\n\t"
//       "mv a5, %4\n\t"
//       "ecall\n\t"
//       "mv %0, a0\n\t"
//       : "=r"(ret)
//       : "r"(a0), "r"(a1), "r"(a2), "r"(type)
//       : "a0", "a1", "a2", "a5");
// #endif
//   return ret;
// }

int main()
{
  return _syscall_(SYS_yield, 0, 0, 0);
}

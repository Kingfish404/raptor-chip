// Modified for NPC/NEMU: no HTIF, uses SBI console calls from S-mode.
// Original riscv-pk frontend.c proxies all syscalls to the host via HTIF.
// This version handles console I/O locally through SBI -> NS16550 UART.

#include "pk.h"
#include "atomic.h"
#include "frontend.h"
#include "syscall.h"
#include "htif.h"
#include "mmap.h"
#include "mcall.h"
#include <stdint.h>
#include <errno.h>
#include <string.h>

// SBI ecall from S-mode -> M-mode mcall_trap handler
static inline long sbi_call(long ext, long arg0)
{
  register long a0 asm("a0") = arg0;
  register long a7 asm("a7") = ext;
  asm volatile("ecall" : "+r"(a0) : "r"(a7) : "memory");
  return a0;
}

long frontend_syscall(long n, uint64_t a0, uint64_t a1, uint64_t a2,
                      uint64_t a3, uint64_t a4, uint64_t a5, uint64_t a6)
{
  switch (n)
  {
  case SYS_write:
  {
    // a0=fd (kfd), a1=buf (physical addr via kva2pa), a2=len
    if (a0 == 1 || a0 == 2)
    { // stdout or stderr
      const char *buf = (const char *)pa2kva(a1);
      for (uint64_t i = 0; i < a2; i++)
        sbi_call(SBI_CONSOLE_PUTCHAR, (uint8_t)buf[i]);
      return (long)a2;
    }
    return -EBADF;
  }

  case SYS_read:
  {
    if (a0 == 0)
    { // stdin
      char *buf = (char *)pa2kva(a1);
      for (uint64_t i = 0; i < a2; i++)
      {
        long ch;
        do
        {
          ch = sbi_call(SBI_CONSOLE_GETCHAR, 0);
        } while (ch < 0);
        buf[i] = (char)ch;
      }
      return (long)a2;
    }
    return -EBADF;
  }

  case SYS_exit:
  case SYS_exit_group:
    shutdown((int)a0);
    __builtin_unreachable();

  case SYS_fstat:
  {
    // Return minimal stat for stdin/stdout/stderr so newlib doesn't error
    struct frontend_stat *st = (struct frontend_stat *)pa2kva(a1);
    memset(st, 0, sizeof(*st));
    st->mode = 0020000 | 0666; // S_IFCHR | rw-rw-rw-
    return 0;
  }

  case SYS_close:
    // Silently succeed for stdin/stdout/stderr
    if (a0 <= 2)
      return 0;
    return -EBADF;

  case SYS_lseek:
    return -ESPIPE; // not seekable (pipe/char device)

  case SYS_openat:
  case SYS_getcwd:
  case SYS_getmainvars:
    return -ENOSYS;

  default:
    return -ENOSYS;
  }
}

void shutdown(int code)
{
  sbi_call(SBI_SHUTDOWN, code);
  while (1)
    ;
}

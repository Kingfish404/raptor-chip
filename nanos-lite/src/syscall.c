#include <common.h>
#include "syscall.h"

#define CONFIG_STRACE

void sys_yield(Context *c)
{
  yield();
  c->GPRx = 0;
}

void sys_exit(Context *c)
{
  halt(c->GPR1);
}

void sys_write(Context *c)
{
  if (c->GPR2 == 1 || c->GPR2 == 2)
  {
    for (int i = 0; i < c->GPR4; i++)
    {
      putch(*(char *)(c->GPR3 + i));
    }
    c->GPRx = c->GPR4;
  }
  else
  {
    panic("sys_write: not implemented");
  }
}

void sys_brk(Context *c)
{
  c->GPRx = 0;
}

static void strace(Context *c)
{
#ifdef CONFIG_STRACE
  Log("syscall ID = 0x%x, GPR1 = 0x%x, GPR2 = 0x%x, GPR3 = 0x%x, GPR4 = 0x%x",
      c->mcause, c->GPR1, c->GPR2, c->GPR3, c->GPR4);
#endif
}

void do_syscall(Context *c)
{
  uintptr_t a[4];
  a[0] = c->GPR1;

  strace(c);

  switch (a[0])
  {
  case SYS_exit:
    sys_exit(c);
  case SYS_yield:
    sys_yield(c);
    break;
  case SYS_write:
    sys_write(c);
    break;
  case SYS_brk:
    sys_brk(c);
    break;
  default:
    panic("Unhandled syscall ID = %d", a[0]);
  }
}

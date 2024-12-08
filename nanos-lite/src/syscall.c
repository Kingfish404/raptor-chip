#include <common.h>
#include <fs.h>
#include <proc.h>
#include <sys/time.h>
#include "syscall.h"

void naive_uload(PCB *pcb, const char *filename);
void context_uload(PCB *pcb, const char *filename, char *const argv[], char *const envp[]);
void switch_boot_pcb();

// #define CONFIG_STRACE

void sys_yield(Context *c)
{
  yield();
  c->GPRx = 0;
}

void sys_exit(Context *c)
{
  naive_uload(NULL, "/bin/nterm");
  c->GPRx = 0;
}

void sys_open(Context *c)
{
  c->GPRx = fs_open((char *)c->GPR2, c->GPR3, c->GPR4);
}

void sys_write(Context *c)
{
  int ret = fs_write(c->GPR2, (void *)c->GPR3, c->GPR4);
  c->GPRx = ret;
}

void sys_brk(Context *c)
{
  c->GPRx = 0;
}

void sys_read(Context *c)
{
  int ret = fs_read(c->GPR2, (void *)c->GPR3, c->GPR4);
  c->GPRx = ret;
}

void sys_close(Context *c)
{
  int ret = fs_close(c->GPR2);
  c->GPRx = ret;
}

void sys_lseek(Context *c)
{
  int ret = fs_lseek(c->GPR2, c->GPR3, c->GPR4);
  c->GPRx = ret;
}

void sys_gettimeofday(Context *c)
{
  struct timeval *tv = (struct timeval *)c->GPR2;
  size_t time = io_read(AM_TIMER_UPTIME).us;
  tv->tv_usec = (size_t)((size_t)time % 1000000);
  tv->tv_sec = (size_t)((size_t)time / 1000000);
  c->GPRx = 0;
}

void sys_execve(Context *c)
{
  const char *fname = (const char *)c->GPR2;
  const void *argv = (const void *)c->GPR3;
  const void *envp = (const void *)c->GPR4;
  if (fs_open(fname, 0, 0) == -1)
  {
    c->GPRx = -1;
    return;
  }
  // naive_uload(NULL, fname);
  // c->GPRx = 0;
  // Log("execve: fname %s, argv %p, envp %p", fname, argv, envp);
  context_uload(current, fname, argv, envp);
  switch_boot_pcb();
  yield();
}

static void strace(Context *c)
{
#ifdef CONFIG_STRACE
  Log("syscall ID = 0x%x, GPR1 = 0x%x, GPR2 = 0x%x, GPR3 = 0x%x, GPR4 = 0x%x",
      c->mcause, c->GPR1, c->GPR2, c->GPR3, c->GPR4);
  if (c->mcause == SYS_open)
  {
    Log("path = %s, flags = %d, mode = %d", (char *)c->GPR2, c->GPR3, c->GPR4);
  }
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
    break;
  case SYS_open:
    sys_open(c);
    break;
  case SYS_yield:
    sys_yield(c);
    break;
  case SYS_write:
    sys_write(c);
    break;
  case SYS_brk:
    sys_brk(c);
    break;
  case SYS_read:
    sys_read(c);
    break;
  case SYS_close:
    sys_close(c);
    break;
  case SYS_lseek:
    sys_lseek(c);
    break;
  case SYS_gettimeofday:
    sys_gettimeofday(c);
    break;
  case SYS_execve:
    sys_execve(c);
    break;
  default:
    panic("Unhandled syscall ID = %d", a[0]);
  }
}

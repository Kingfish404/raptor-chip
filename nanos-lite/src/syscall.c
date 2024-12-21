#include <common.h>
#include <fs.h>
#include <proc.h>
#include <sys/time.h>
#include <errno.h>
#include "syscall.h"

void naive_uload(PCB *pcb, const char *filename);
void context_uload(PCB *pcb, const char *filename, char *const argv[], char *const envp[]);
void switch_boot_pcb();

// #define CONFIG_STRACE

void sys_exit(Context *c)
{
  naive_uload(NULL, "/bin/nterm");
  c->GPRx = 0;
}

int sys_gettimeofday(struct timeval *tv)
{
  size_t time = io_read(AM_TIMER_UPTIME).us;
  tv->tv_usec = (size_t)((size_t)time % 1000000);
  tv->tv_sec = (size_t)((size_t)time / 1000000);
  return 0;
}

int sys_execve(const char *fname, const void *argv, const void *envp)
{
  // const char *fname = (const char *)c->GPR2;
  // const void *argv = (const void *)c->GPR3;
  // const void *envp = (const void *)c->GPR4;
  printf("execve: fname %s, argv %p, env: %p\n",
         fname, argv, envp);
  if (fs_open(fname, 0, 0) == -1)
  {
    return ENOENT;
  }
  // naive_uload(NULL, fname);
  // c->GPRx = 0;
  // Log("execve: fname %s, argv %p, envp %p", fname, argv, envp);
  context_uload(current, fname, argv, envp);
  switch_boot_pcb();
  yield();
  return 0;
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
  a[1] = c->GPR2;
  a[2] = c->GPR3;
  a[3] = c->GPR4;

  strace(c);

  switch (a[0])
  {
  case SYS_exit:
    // sys_exit(c);
    char *argv[] = {"/bin/menu", NULL};
    char *envp[] = {NULL};
    c->GPRx = sys_execve(argv[0], argv, envp);
    break;
  case SYS_open:
    c->GPRx = fs_open((char *)a[1], a[2], a[3]);
    break;
  case SYS_yield:
    yield();
    c->GPRx = 0;
    break;
  case SYS_write:
    c->GPRx = fs_write(a[1], (void *)a[2], a[3]);
    break;
  case SYS_brk:
    c->GPRx = 0;
    break;
  case SYS_read:
    c->GPRx = fs_read(a[1], (void *)a[2], a[3]);
    break;
  case SYS_close:
    c->GPRx = fs_close(a[1]);
    break;
  case SYS_lseek:
    c->GPRx = fs_lseek(a[1], a[2], a[3]);
    break;
  case SYS_gettimeofday:
    c->GPRx = sys_gettimeofday((struct timeval *)a[1]);
    break;
  case SYS_execve:
    c->GPRx = sys_execve((const char *)a[1], (const void *)a[2], (const void *)a[3]);
    break;
  default:
    panic("Unhandled syscall ID = %d", a[0]);
  }
}

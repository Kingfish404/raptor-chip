/*
 * pk_io.c — Picolibc startup + I/O stubs for programs running under riscv-pk
 *
 * When the toolchain ships picolibc (e.g. Ubuntu's riscv64-unknown-elf-gcc)
 * instead of classic newlib, two things are needed:
 *
 *  1. A pk-compatible _start (picolibc's bare-metal crt0 clobbers sp with
 *     an invalid __stack address; pk already sets sp correctly).
 *  2. stdout/stdin/stderr FILE objects + write/read/_exit via ecall, since
 *     picolibc tinystdio expects the application to provide them.
 *
 * Linked with -nostartfiles --specs=picolibc.specs so we get picolibc
 * headers and libc but NOT picolibc's crt0.
 */

#include <stdio.h>
#include <stdint.h>
#include <unistd.h>

/* ---- pk-compatible _start ----
 * riscv-pk sets up the user stack in Linux ABI fashion:
 *   sp -> [ argc | argv[0] | ... | argv[argc-1] | NULL | envp... ]
 * We just extract argc/argv and call main().
 */
extern int main(int argc, char **argv);

__attribute__((naked, section(".text.startup"))) void _start(void)
{
  __asm__ volatile(
      ".option push\n"
      ".option norelax\n"
#if __riscv_xlen == 64
      "ld    a0, 0(sp)\n" /* argc */
      "addi  a1, sp, 8\n" /* argv */
#else
      "lw    a0, 0(sp)\n" /* argc */
      "addi  a1, sp, 4\n" /* argv */
#endif
      "andi  sp, sp, -16\n" /* 16-byte align sp (ABI) */
      "li    gp, 0\n"
      "li    s0, 0\n" /* clear frame pointer */
      "call  main\n"
      "call  _exit\n" /* _exit(main's return value in a0) */
      ".option pop\n");
}

/* ---- Linux RISC-V syscall numbers ---- */
#define SYS_read 63
#define SYS_write 64
#define SYS_exit 93

static inline long _pk_ecall(long n, long a0, long a1, long a2)
{
  register long _a0 __asm__("a0") = a0;
  register long _a1 __asm__("a1") = a1;
  register long _a2 __asm__("a2") = a2;
  register long _n __asm__("a7") = n;
  __asm__ volatile("ecall"
                   : "+r"(_a0)
                   : "r"(_a1), "r"(_a2), "r"(_n)
                   : "memory");
  return _a0;
}

/* POSIX-like write/read used by picolibc internally */
ssize_t write(int fd, const void *buf, size_t count)
{
  return _pk_ecall(SYS_write, fd, (long)buf, (long)count);
}

ssize_t read(int fd, void *buf, size_t count)
{
  return _pk_ecall(SYS_read, fd, (long)buf, (long)count);
}

void _exit(int status)
{
  _pk_ecall(SYS_exit, status, 0, 0);
  __builtin_unreachable();
}

/* ---- picolibc tinystdio FILE objects ---- */

static int _pk_putc(char c, FILE *f)
{
  (void)f;
  return (write(1, &c, 1) == 1) ? c : -1;
}

static int _pk_getc(FILE *f)
{
  unsigned char c;
  (void)f;
  return (read(0, &c, 1) == 1) ? (int)c : -1;
}

static int _pk_flush(FILE *f)
{
  (void)f;
  return 0;
}

static FILE _stdout = FDEV_SETUP_STREAM(_pk_putc, NULL, _pk_flush, _FDEV_SETUP_WRITE);
static FILE _stderr = FDEV_SETUP_STREAM(_pk_putc, NULL, _pk_flush, _FDEV_SETUP_WRITE);
static FILE _stdin = FDEV_SETUP_STREAM(NULL, _pk_getc, NULL, _FDEV_SETUP_READ);

FILE *const stdout = &_stdout;
FILE *const stderr = &_stderr;
FILE *const stdin = &_stdin;

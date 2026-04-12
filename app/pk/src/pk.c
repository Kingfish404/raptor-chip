// Modified pk.c: supports embedded ELF payload (no HTIF filesystem).
// When _payload_start != _payload_end, loads the embedded payload.
// Otherwise falls back to original HTIF-based loading.

#include "pk.h"
#include "mmap.h"
#include "boot.h"
#include "elf.h"
#include "mtrap.h"
#include "frontend.h"
#include "bits.h"
#include "usermem.h"
#include "flush_icache.h"
#include "elf_mem.h"
#include <stdbool.h>

elf_info current;
long disabled_hart_mask;
static bool zicfilp_enabled;
static bool zicfiss_enabled;

// Embedded payload symbols (from payload.S)
extern char _payload_start;
extern char _payload_end;

static void init_tf(trapframe_t* tf, long pc, long sp)
{
  memset(tf, 0, sizeof(*tf));
  // Minimal status: SPIE only, avoid FS/VS that NPC might not handle
  tf->status = SSTATUS_SPIE;
  tf->gpr[2] = sp;
  tf->epc = pc;
}

static void run_loaded_program(size_t argc, char** argv, uintptr_t kstack_top)
{
  size_t mem_pages = mem_size >> RISCV_PGSHIFT;
  size_t stack_size = MIN(mem_pages >> 5, 2048) * RISCV_PGSIZE;
  size_t stack_bottom = __do_mmap(current.mmap_max - stack_size, stack_size, PROT_READ|PROT_WRITE|PROT_EXEC, MAP_PRIVATE|MAP_ANONYMOUS|MAP_FIXED|MAP_POPULATE, 0, 0);
  kassert(stack_bottom != (uintptr_t)-1);
  current.stack_top = stack_bottom + stack_size;

  if (zicfiss_enabled) {
    size_t shadow_stack_size = MAX(RISCV_PGSIZE, stack_size >> 5);
    size_t shadow_stack_bottom = __do_mmap(stack_bottom - shadow_stack_size, shadow_stack_size, PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS|MAP_FIXED, 0, 0);
    kassert(shadow_stack_bottom != (uintptr_t)-1);
    size_t shadow_stack_top = shadow_stack_bottom + shadow_stack_size;

    set_csr(senvcfg, SENVCFG_SSE);
    asm volatile ("csrw %0, %1" :: "I" (CSR_SSP), "r" (shadow_stack_top) : "memory");
  }

  // NPC/NEMU: skip senvcfg (CSR 0x10A) — not implemented
  // set_csr(senvcfg, SENVCFG_CBCFE | INSERT_FIELD(0, SENVCFG_CBIE, 1));

  // copy phdrs to user stack
  size_t stack_top = current.stack_top - current.phdr_size;
  memcpy_to_user((void*)stack_top, (void*)current.phdr, current.phdr_size);
  current.phdr = stack_top;

  // copy argv to user stack
  for (size_t i = 0; i < argc; i++) {
    size_t len = strlen((char*)(uintptr_t)argv[i])+1;
    stack_top -= len;
    memcpy_to_user((void*)stack_top, (void*)(uintptr_t)argv[i], len);
    argv[i] = (void*)stack_top;
  }

  // copy envp to user stack
  const char* envp[] = {
    // environment goes here
  };
  size_t envc = sizeof(envp) / sizeof(envp[0]);
  for (size_t i = 0; i < envc; i++) {
    size_t len = strlen(envp[i]) + 1;
    stack_top -= len;
    memcpy_to_user((void*)stack_top, envp[i], len);
    envp[i] = (void*)stack_top;
  }

  // align stack
  stack_top &= -sizeof(void*);

  struct {
    long key;
    long value;
  } aux[] = {
    {AT_ENTRY, current.entry},
    {AT_PHNUM, current.phnum},
    {AT_PHENT, current.phent},
    {AT_PHDR, current.phdr},
    {AT_PAGESZ, RISCV_PGSIZE},
    {AT_SECURE, 0},
    {AT_RANDOM, stack_top},
    {AT_NULL, 0}
  };

  // place argc, argv, envp, auxp on stack
  #define PUSH_ARG(type, value) do { \
    type __tmp = (type)(value); \
    memcpy_to_user(sp, &__tmp, sizeof(type)); \
    sp ++; \
  } while (0)

  #define STACK_INIT(type) do { \
    unsigned naux = sizeof(aux)/sizeof(aux[0]); \
    stack_top -= (1 + argc + 1 + envc + 1 + 2*naux) * sizeof(type); \
    stack_top &= -16; \
    type *sp = (void*)stack_top; \
    PUSH_ARG(int, argc); \
    for (unsigned i = 0; i < argc; i++) \
      PUSH_ARG(type, argv[i]); \
    PUSH_ARG(type, 0); /* argv[argc] = NULL */ \
    for (unsigned i = 0; i < envc; i++) \
      PUSH_ARG(type, envp[i]); \
    PUSH_ARG(type, 0); /* envp[envc] = NULL */ \
    for (unsigned i = 0; i < naux; i++) { \
      PUSH_ARG(type, aux[i].key); \
      PUSH_ARG(type, aux[i].value); \
    } \
  } while (0)

  STACK_INIT(uintptr_t);

  if (current.cycle0) { // start timer if so requested
    current.time0 = rdtime64();
    current.cycle0 = rdcycle64();
    current.instret0 = rdinstret64();
  }

  static trapframe_t tf;  // static: out of stack to prevent corruption
  init_tf(&tf, current.entry, stack_top);
  __riscv_flush_icache();
  write_csr(sscratch, kstack_top);
  if (zicfilp_enabled)
    set_csr(senvcfg, SENVCFG_LPE);
  start_user(&tf);
}

void rest_of_boot_loader(uintptr_t kstack_top);

asm ("\n\
  .pushsection .text\n\
  .globl rest_of_boot_loader\n\
rest_of_boot_loader:\n\
  mv sp, a0\n\
  tail rest_of_boot_loader_2\n\
  .popsection");

void rest_of_boot_loader_2(uintptr_t kstack_top)
{
  file_init();

  static long phdrs[128]; // avoid large stack allocation
  current.phdr = (uintptr_t)phdrs;
  current.phdr_size = sizeof(phdrs);

  // Check for embedded payload
  size_t payload_size = &_payload_end - &_payload_start;
  if (payload_size > 0) {
    load_elf_mem(&_payload_start, payload_size, &current);

    static char progname[] = "payload";
    static char *argv[] = { progname };
    run_loaded_program(1, argv, kstack_top);
  } else {
    panic("no embedded payload (HTIF loading not supported on this platform)");
  }
}

void boot_loader(uintptr_t dtb)
{
  uintptr_t kernel_stack_top = pk_vm_init();

  extern char trap_entry;
  write_csr(stvec, pa2kva(&trap_entry));
  write_csr(sscratch, 0);
  write_csr(sie, 0);
  set_csr(sstatus, SSTATUS_FS | SSTATUS_VS);

  enter_supervisor_mode((void*)pa2kva(rest_of_boot_loader), pa2kva(kernel_stack_top), 0);
}

void boot_other_hart(uintptr_t dtb)
{
  // stall all harts besides hart 0
  while (1)
    wfi();
}

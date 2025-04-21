#include <am.h>
#include <nemu.h>
#include <klib.h>

static AddrSpace kas = {};
static void *(*pgalloc_usr)(int) = NULL;
static void (*pgfree_usr)(void *) = NULL;
static int vme_enable = 0;

static Area segments[] = { // Kernel memory mappings
    NEMU_PADDR_SPACE};

#define USER_SPACE RANGE(0x40000000, 0x80000000)

static inline void set_satp(void *pdir)
{
  uintptr_t mode = 1ul << (__riscv_xlen - 1);
  asm volatile("csrw satp, %0" : : "r"(mode | ((uintptr_t)pdir >> 12)));
}

static inline uintptr_t get_satp()
{
  uintptr_t satp;
  asm volatile("csrr %0, satp" : "=r"(satp));
  return satp << 12;
}

bool vme_init(void *(*pgalloc_f)(int), void (*pgfree_f)(void *))
{
  pgalloc_usr = pgalloc_f;
  pgfree_usr = pgfree_f;

  kas.ptr = pgalloc_f(PGSIZE);

  int i;
  for (i = 0; i < LENGTH(segments); i++)
  {
    void *va = segments[i].start;
    for (; va < segments[i].end; va += PGSIZE)
    {
      map(&kas, va, va, (PTE_A | PTE_D | PTE_R | PTE_W | PTE_U));
    }
  }

  set_satp(kas.ptr);
  vme_enable = 1;

  return true;
}

void protect(AddrSpace *as)
{
  PTE *updir = (PTE *)(pgalloc_usr(PGSIZE));
  as->ptr = updir;
  as->area = USER_SPACE;
  as->pgsize = PGSIZE;
  // map kernel space
  memcpy(updir, kas.ptr, PGSIZE);
}

void unprotect(AddrSpace *as)
{
}

void __am_get_cur_as(Context *c)
{
  c->pdir = (vme_enable ? (void *)get_satp() : NULL);
}

void __am_switch(Context *c)
{
  if (vme_enable && c->pdir != NULL)
  {
    set_satp(c->pdir);
  }
}

void map(AddrSpace *as, void *va, void *pa, int prot)
{
  PTE *pdir = (PTE *)as->ptr;
#if __riscv_xlen == 32
  uintptr_t vpn1 = (uintptr_t)va >> 22;
  uintptr_t vpn0 = (uintptr_t)va >> 12 & 0x3ff;
  uintptr_t ppn1 = (uintptr_t)pa >> 22;
  uintptr_t ppn0 = (uintptr_t)pa >> 12 & 0x3ff;
  // printf("va: %x, pa: %x\t", va, pa);
  // printf("vpn1: %x, vpn0: %x, ppn1: %x, ppn0: %x\n", vpn1, vpn0, ppn1, ppn0);
  if (pdir[vpn1] == NULL)
  {
    uintptr_t l1 = (uintptr_t)pgalloc_usr(PGSIZE);
    pdir[vpn1] = (l1 >> 2) | PTE_V;
  }
  PTE *pte1 = ((PTE *)((pdir[vpn1] << 2) & ~0xfff));
  (pte1)[vpn0] = ((ppn1 << 20) | (ppn0 << 10) | prot | PTE_V);
#else
  panic("not implemented");
#endif
}

Context *ucontext(AddrSpace *as, Area ustack, void *entry)
{
  Context *c = (Context *)(ustack.end - sizeof(Context));

  c->mepc = (uintptr_t)entry;

#ifdef CONFIG_ISA64
  c->mstatus = 0xa00001800;
#else // __risv32
  csr_t csr = {.val = 0x0};
  csr.mstatus.mpp = PRV_U;
  csr.mstatus.sum = 1;
  csr.mstatus.mxr = 1;
  csr.mstatus.mie = 1;
  c->mstatus = csr.val;
#endif
  c->pdir = as->ptr;
  c->np = PRV_U;
  return c;
}

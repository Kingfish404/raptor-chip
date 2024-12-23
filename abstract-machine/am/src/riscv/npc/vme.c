#include <am.h>

bool vme_init(void *(*pgalloc_f)(int), void (*pgfree_f)(void *))
{
  return false;
}

void protect(AddrSpace *as)
{
}

void unprotect(AddrSpace *as)
{
}

void map(AddrSpace *as, void *va, void *pa, int prot)
{
}

Context *ucontext(AddrSpace *as, Area ustack, void *entry)
{
  Context *c = (Context *)(ustack.end - sizeof(Context));

  c->mepc = (uintptr_t)entry;

#ifdef CONFIG_ISA64
  c->mstatus = 0xa00001800;
#else // __risv32
  c->mstatus = 0x1800;
#endif
  return c;
}

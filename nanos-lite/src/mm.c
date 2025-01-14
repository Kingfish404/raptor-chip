#include <memory.h>
#include <proc.h>

static void *pf = NULL;

void *new_page(size_t nr_page)
{
  void *p = pf;
  pf += nr_page * PGSIZE;
  return p;
}

#ifdef HAS_VME
static void *pg_alloc(int n)
{
  size_t page_num = (n + PGSIZE - 1) / PGSIZE;
  void *p = new_page(page_num);
  assert(p != NULL);
  if (p != NULL)
  {
    memset(p, 0, n);
  }
  return p;
}
#endif

void free_page(void *p)
{
  panic("not implement yet");
}

/* The brk() system call handler. */
int mm_brk(uintptr_t brk)
{
  int page_num = ((brk + PGSIZE - 1) / PGSIZE);
  int sbrk = (int)(brk);
  // printf("brk: %d, sbrk: %d, page_num: %d, cur_max_brk: %x\n", brk, page_num, current->max_brk);
  if (page_num == 0 || sbrk < 0)
  {
    return 0;
  }
  void *pg = new_page(page_num);
  for (int i = 0; i < page_num; i++)
  {
    map(&current->as, (void *)(current->max_brk + i * PGSIZE),
        pg + i * PGSIZE, (PTE_A | PTE_D | PTE_R | PTE_W | PTE_U));
  }
  current->max_brk += page_num * PGSIZE;
  return 0;
}

void init_mm()
{
  pf = (void *)ROUNDUP(heap.start, PGSIZE);
  Log("free physical pages starting from %p", pf);

#ifdef HAS_VME
  vme_init(pg_alloc, free_page);
#endif
}

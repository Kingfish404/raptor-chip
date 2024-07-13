#include <proc.h>

#define MAX_NR_PROC 4

void naive_uload(PCB *pcb, const char *filename);
uintptr_t ucontext_load(PCB *pcb, const char *filename);

static PCB pcb[MAX_NR_PROC] __attribute__((used)) = {};
static PCB pcb_boot = {};
PCB *current = NULL;
PCB *last = NULL;

void switch_boot_pcb()
{
  current = &pcb_boot;
}

void hello_fun(void *arg)
{
  int j = 1;
  while (1)
  {
    Log("Hello World from Nanos-lite with arg '%s' for the %dth time!", (const char *)arg, j);
    j++;
    yield();
  }
}

void context_kload(PCB *pcb, void *entry, void *arg)
{
  pcb->cp = kcontext((Area){pcb->stack, pcb->stack + STACK_SIZE}, entry, arg);
}

void context_uload(PCB *pcb, const char *filename)
{
  void *entry = ucontext_load(pcb, filename);
  pcb->cp = ucontext(NULL, (Area){pcb->stack, pcb->stack + STACK_SIZE}, entry);
}

void init_proc()
{
  context_kload(&pcb[0], hello_fun, "pcb[0]");
  context_kload(&pcb[1], hello_fun, "pcb[1]");
  context_uload(&pcb[2], "/bin/pal");
  last = &pcb[2];
  switch_boot_pcb();

  Log("Initializing processes...");

  // load program here
  naive_uload(NULL, "/bin/dummy");
}

Context *schedule(Context *prev)
{
  current->cp = prev;
  if (current == last)
  {
    current = &pcb[0];
  }
  else
  {
    current++;
  }
  return current->cp;
}
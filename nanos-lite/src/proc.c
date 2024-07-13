#include <proc.h>

#define MAX_NR_PROC 4

void naive_uload(PCB *pcb, const char *filename);
Context *schedule(Context *prev);

static PCB pcb[MAX_NR_PROC] __attribute__((used)) = {};
static PCB pcb_boot = {};
PCB *current = NULL;

void switch_boot_pcb()
{
  current = &pcb_boot;
  cte_init(schedule);
  yield();
}

void hello_fun(void *arg)
{
  int j = 1;
  while (1)
  {
    Log("Hello World from Nanos-lite with arg '%p' for the %dth time!", (uintptr_t)arg, j);
    j++;
    yield();
  }
}

void context_kload(PCB *pcb, void *entry, void *arg)
{
  pcb->cp = kcontext((Area){pcb->stack, pcb->stack + STACK_SIZE}, entry, arg);
  printf("pcb->cp: %p\n", pcb->cp);
}

void init_proc()
{
  context_kload(&pcb[0], hello_fun, "111");
  context_kload(&pcb[1], hello_fun, "123");

  switch_boot_pcb();

  // Log("Initializing processes...");

  // // load program here
  // naive_uload(NULL, "/bin/nterm");
}

Context *schedule(Context *prev)
{
  current = (current == &pcb[0] ? &pcb[1] : &pcb[0]);
  return current->cp;
}

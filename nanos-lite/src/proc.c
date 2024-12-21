#include <proc.h>

#define MAX_NR_PROC 4

void naive_uload(PCB *pcb, const char *filename);
void context_kload(PCB *pcb, void *entry, void *arg);
void context_uload(PCB *pcb, const char *filename, char *const argv[], char *const envp[]);

static PCB pcb[MAX_NR_PROC] __attribute__((used)) = {};
static PCB pcb_boot = {};
PCB *current = NULL;

void switch_boot_pcb()
{
  current = &pcb_boot;
}

void hello_fun(void *arg)
{
  int j = 1;
  while (1)
  {
    if (j % 0x1000 == 0)
    {
      Log("Hello World from Nanos-lite with arg '%p' for the %dth time!", (uintptr_t)arg, j);
    }
    j++;
    yield();
  }
}

void init_proc()
{
  char *envp[] = {NULL};

  context_kload(&pcb[0], hello_fun, (void *)0);
  // char *argv[] = {"/bin/menu", NULL};
  // char *argv[] = {"/bin/nterm", NULL};
  // char *argv[] = {"/bin/pal", "--skip", NULL};
  char *argv[] = {"/usr/bin/wc", "/share/files/num", NULL};
  // char *argv[] = {"/bin/printenv", "hello", NULL};
  context_uload(&pcb[1], argv[0], argv, envp);
  // context_kload(&pcb[1], hello_fun, (void *)1);
  switch_boot_pcb();
  yield();

  Log("Initializing processes...");

  // load program here
  naive_uload(NULL, "/bin/nterm");
}

Context *schedule(Context *prev)
{
  current->cp = prev;
  current = (current == &pcb[0] ? &pcb[1] : &pcb[0]);
  return current->cp;
}

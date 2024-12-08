#include <stdint.h>
#include <stdlib.h>
#include <assert.h>

int main(int argc, char *argv[], char *envp[]);
extern char **environ;
void call_main(uintptr_t *args)
{
  void *p_args = args;

  int argc = ((int *)p_args)[0];
  p_args += sizeof(int);

  char **argv = (char **)p_args;
  p_args += sizeof(char *) * (argc + 1);

  char **envp = (char **)p_args;
  char *p = (char *)argv;
  environ = envp;
  exit(main(argc, argv, envp));
  assert(0);
}

#include <common.h>

void init_monitor(int, char *[]);
void sim(int argc, char **argv);

int main(int argc, char *argv[])
{
  init_monitor(argc, argv);
  sim(argc, argv);
  return 0;
}
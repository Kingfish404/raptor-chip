#include <cpu/icache.h>
#include <string.h>

icache_entry_t icache[ICACHE_SIZE];
uint32_t icache_epoch = 1;

void icache_flush(void)
{
  if (++icache_epoch == 0)
  {
    memset(icache, 0, sizeof(icache));
    icache_epoch = 1;
  }
}

#ifndef RAPTOR_SIM_HTIF_H
#define RAPTOR_SIM_HTIF_H

#include <common.h>

// Optional memory-backed HTIF exit protocol; ordinary RAM writes remain unchanged.
int htif_set_tohost(const char *address);
void htif_observe_write(paddr_t address, uint8_t mask);

#endif

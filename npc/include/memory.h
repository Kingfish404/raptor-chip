#ifndef __NPC_MEMORY_H__
#define __NPC_MEMORY_H__
#include <common.h>

uint8_t *guest_to_host(paddr_t addr);

paddr_t host_to_guest(uint8_t *addr);

static inline word_t host_read(void *addr, int len);

extern "C" void pmem_read(word_t addr, word_t *data);

extern "C" void pmem_write(word_t addr, char data);

void vaddr_show(vaddr_t addr, int n);

#endif /* __NPC_MEMORY_H__ */
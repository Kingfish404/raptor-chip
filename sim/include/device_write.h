#pragma once
#include <stddef.h>
#include <stdint.h>

// FIFO of precise physical byte ranges written by NPC DMA device models.
bool device_write_front(uint64_t *first, uint64_t *last);
void device_write_consume();
void device_write_reset();

// Shared non-coherent DMA memory helpers: notify rapt core's LR/SC reservation
// tracker (via device_write_*) and mirror DMA writes into difftest REF.
bool dma_guest_read(uint64_t addr, void *buf, size_t len);
bool dma_guest_write(uint64_t addr, const void *buf, size_t len);

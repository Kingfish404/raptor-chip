#pragma once
#include <stdint.h>

// FIFO of precise physical byte ranges written by the NPC device model.
bool device_write_front(uint64_t *first, uint64_t *last);
void device_write_consume();
void device_write_reset();

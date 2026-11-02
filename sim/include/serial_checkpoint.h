#ifndef NPC_SERIAL_CHECKPOINT_H
#define NPC_SERIAL_CHECKPOINT_H

#include <stdint.h>

/* NS16550 configuration with no queued RX. Preserve the TX-empty interrupt latch. */
struct SerialCheckpoint {
  uint32_t values[8]; // IER, LCR, MCR, SCR, DLL, DLM, FCR, TX pending
};
void serial_restore_checkpoint(const SerialCheckpoint &state);

#endif

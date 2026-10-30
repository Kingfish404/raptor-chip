#include <htif.h>
#include <memory.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <verilated.h>

extern NPCState npc;
extern VerilatedContext *contextp;
void npc_abort();

static uint64_t tohost_address = 0;

int htif_set_tohost(const char *address)
{
  char *end = nullptr;
  errno = 0;
  uint64_t value = strtoull(address, &end, 0);
  if (errno || address[0] == '-' || end == address || *end != '\0' || (value & 7)
      || value < uint64_t(MBASE) || value - uint64_t(MBASE) > uint64_t(MSIZE) - 8)
    return -1;
  tohost_address = value;
  printf("HTIF: configured XLEN=%u tohost=0x%llx\n", unsigned(sizeof(word_t) * 8),
         (unsigned long long)value);
  return 0;
}

void htif_observe_write(paddr_t address, uint8_t mask)
{
  if (tohost_address == 0) return;
  bool overlaps = false;
  for (unsigned lane = 0; lane < sizeof(word_t); ++lane)
    if ((mask & (1u << lane)) && uint64_t(address) + lane >= tohost_address
        && uint64_t(address) + lane - tohost_address < 8)
      overlaps = true;
  if (!overlaps) return;

  // Read the complete little-endian mailbox after applying the selected bytes.
  // RV32 tests publish the low word before clearing the high word.
  const uint8_t *bytes = guest_to_host(paddr_t(tohost_address));
  uint64_t value = 0;
  for (unsigned lane = 0; lane < 8; ++lane)
    value |= uint64_t(bytes[lane]) << (8 * lane);
  // Device=0, command=0, odd payload is the HTIF test exit convention.
  // Zero/even payloads and console/device commands must not report test success.
  if ((value >> 48) != 0 || (value & 1) == 0) return;
  uint64_t code = value >> 1;
  Log("HTIF: tohost=0x%llx exit=%llu", (unsigned long long)tohost_address,
      (unsigned long long)code);
  if (code == 0)
  {
    npc.host_exit_ok = 1;
    npc.state = NPC_END;
    contextp->gotFinish(true);
  }
  else
    npc_abort();
}

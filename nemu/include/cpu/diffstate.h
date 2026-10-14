#ifndef NEMU_CPU_DIFFSTATE_H
#define NEMU_CPU_DIFFSTATE_H

#include <difftest-multi.h>
#include <string.h>

static inline size_t nemu_diff_state_delta(const NemuDiffState *state,
                                         NemuDiffState *previous, uint64_t *record)
{
  const uint8_t *actual = (const uint8_t *)state;
  uint8_t *saved = (uint8_t *)previous;
  size_t count = 0;
  for (size_t offset = 0; offset < sizeof(*state); offset += 256) {
    size_t length = sizeof(*state) - offset;
    if (length > 256) length = 256;
    if (!memcmp(actual + offset, saved + offset, length)) continue;
    for (size_t within = 0; within < length; within += sizeof(uint64_t)) {
      size_t position = offset + within;
      uint64_t value, old;
      memcpy(&value, actual + position, sizeof(value));
      memcpy(&old, saved + position, sizeof(old));
      if (value != old) {
        record[count++] = position / sizeof(uint64_t);
        record[count++] = value;
        memcpy(saved + position, &value, sizeof(value));
      }
    }
  }
  return count;
}

#endif

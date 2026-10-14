#ifndef NEMU_DIFFTEST_REPLAY_H
#define NEMU_DIFFTEST_REPLAY_H

#include <stdint.h>

#define NEMU_DIFF_REPLAY_VERSION 1u
#define NEMU_DIFF_STREAM_VERSION 1u

typedef struct {
  uint32_t version;
  uint32_t size;
  uint32_t journal_version;
  uint32_t xlen;
  int (*run)(const char *journal);
} NemuReplayAPI;

typedef const NemuReplayAPI *(*NemuReplayQuery)(uint32_t version, uint32_t size);

typedef struct {
  uint32_t version;
  uint32_t size;
  uint32_t journal_version;
  uint32_t xlen;
  int (*run_fd)(int descriptor);
} NemuStreamAPI;

typedef const NemuStreamAPI *(*NemuStreamQuery)(uint32_t version, uint32_t size);

#endif

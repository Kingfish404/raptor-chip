#ifndef NEMU_DIFFTEST_MULTI_H
#define NEMU_DIFFTEST_MULTI_H

#include <stddef.h>
#include <stdint.h>

#define NEMU_DIFF_MULTI_VERSION 1u
#define NEMU_DIFF_MULTI_HARTS 4u
#define NEMU_DIFF_MULTI_EVENTS 64u
#define NEMU_DIFF_MULTI_STRICT_MEMORY 1u

typedef struct {
  uint64_t pc;
  uint64_t gpr[32];
  uint64_t fpr[32];
  uint64_t csr[4096];
  uint64_t reservation;
  uint64_t mtimecmp;
  uint32_t privilege;
  uint32_t reservation_bytes;
  uint32_t stip;
  uint32_t seip;
} NemuDiffState;

typedef struct {
  uint64_t address;
  uint64_t data;
  uint32_t size;
  uint32_t write;
} NemuDiffMemory;

typedef struct {
  NemuDiffState state;
  NemuDiffMemory memory[NEMU_DIFF_MULTI_EVENTS];
  uint32_t count;
  uint32_t error;
  uint32_t trapped;
  uint32_t ended;
} NemuDiffFrame;

typedef struct {
  uint32_t version;
  uint32_t size;
  uint32_t xlen;
  uint32_t max_harts;
  uint64_t capabilities;
  uint64_t ram_base;
  uint64_t ram_size;
  uint64_t isa_features;
  int (*init)(uint32_t harts);
  int (*set_state)(uint32_t hart, const NemuDiffState *state);
  int (*get_state)(uint32_t hart, NemuDiffState *state);
  int (*memory_copy)(uint64_t address, void *buffer, size_t size, uint32_t to_ref);
  int (*step)(uint32_t hart, uint64_t sequence, NemuDiffFrame *frame);
} NemuDiffAPI;

typedef const NemuDiffAPI *(*NemuDiffQuery)(uint32_t version, uint32_t size);

#endif

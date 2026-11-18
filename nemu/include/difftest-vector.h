#ifndef NEMU_DIFFTEST_VECTOR_H
#define NEMU_DIFFTEST_VECTOR_H

#include <stdint.h>

#define NEMU_DIFF_VECTOR_VERSION 1u
#define NEMU_DIFF_VECTOR_VLENB 16u

typedef struct {
  uint8_t reg[32][NEMU_DIFF_VECTOR_VLENB];
} NemuDiffVectorState;

typedef struct {
  uint32_t version;
  uint32_t size;
  uint32_t xlen;
  uint32_t max_harts;
  int (*set_state)(uint32_t hart, const NemuDiffVectorState *state);
  int (*get_state)(uint32_t hart, NemuDiffVectorState *state);
} NemuDiffVectorAPI;

typedef const NemuDiffVectorAPI *(*NemuDiffVectorQuery)(uint32_t version, uint32_t size);

// Fixed-width sidecar keeps the legacy scalar register-copy ABI unchanged.
// Order: vstart, vxsat, vxrm, vcsr, vl, vtype, vlenb.
#define NEMU_DIFF_VECTOR_CSR_VERSION 1u
#define NEMU_DIFF_VECTOR_CSR_COUNT 7u
typedef struct {
  uint64_t value[NEMU_DIFF_VECTOR_CSR_COUNT];
} NemuDiffVectorCSRs;

typedef struct {
  uint32_t version;
  uint32_t size;
  uint32_t xlen;
  uint32_t reserved;
  int (*set_state)(uint32_t hart, const NemuDiffVectorCSRs *state);
  int (*get_state)(uint32_t hart, NemuDiffVectorCSRs *state);
} NemuDiffVectorCSRAPI;

typedef const NemuDiffVectorCSRAPI *(*NemuDiffVectorCSRQuery)(uint32_t version, uint32_t size);

#endif

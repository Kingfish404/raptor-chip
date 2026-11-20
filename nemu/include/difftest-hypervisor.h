#ifndef NEMU_DIFFTEST_HYPERVISOR_H
#define NEMU_DIFFTEST_HYPERVISOR_H

#include <stdint.h>

#define NEMU_DIFF_HYPERVISOR_VERSION 1u
#define NEMU_DIFF_HYPERVISOR_CSR_COUNT 34u

enum {
  NEMU_DIFF_HCSR_MENVCFG = 0,
  NEMU_DIFF_HCSR_SENVCFG,
  NEMU_DIFF_HCSR_MSTATEEN0,
  NEMU_DIFF_HCSR_MSTATEEN1,
  NEMU_DIFF_HCSR_MSTATEEN2,
  NEMU_DIFF_HCSR_MSTATEEN3,
  NEMU_DIFF_HCSR_HSTATUS,
  NEMU_DIFF_HCSR_HEDELEG,
  NEMU_DIFF_HCSR_HIDELEG,
  NEMU_DIFF_HCSR_HIE,
  NEMU_DIFF_HCSR_HTIMEDELTA,
  NEMU_DIFF_HCSR_HCOUNTEREN,
  NEMU_DIFF_HCSR_HENVCFG,
  NEMU_DIFF_HCSR_HSTATEEN0,
  NEMU_DIFF_HCSR_HSTATEEN1,
  NEMU_DIFF_HCSR_HSTATEEN2,
  NEMU_DIFF_HCSR_HSTATEEN3,
  NEMU_DIFF_HCSR_HTVAL,
  NEMU_DIFF_HCSR_HIP,
  NEMU_DIFF_HCSR_HVIP,
  NEMU_DIFF_HCSR_HTINST,
  NEMU_DIFF_HCSR_HGATP,
  NEMU_DIFF_HCSR_VSSTATUS,
  NEMU_DIFF_HCSR_VSIE,
  NEMU_DIFF_HCSR_VSTVEC,
  NEMU_DIFF_HCSR_VSSCRATCH,
  NEMU_DIFF_HCSR_VSEPC,
  NEMU_DIFF_HCSR_VSCAUSE,
  NEMU_DIFF_HCSR_VSTVAL,
  NEMU_DIFF_HCSR_VSIP,
  NEMU_DIFF_HCSR_VSTIMECMP,
  NEMU_DIFF_HCSR_VSATP,
  NEMU_DIFF_HCSR_MTINST,
  NEMU_DIFF_HCSR_MTVAL2,
};

typedef struct {
  uint8_t virt;
  uint8_t priv;
  uint8_t reserved[6];
  uint64_t csr[NEMU_DIFF_HYPERVISOR_CSR_COUNT];
} NemuDiffHypervisorState;

typedef struct {
  uint32_t version;
  uint32_t size;
  uint32_t xlen;
  uint32_t reserved;
  int (*set_state)(uint32_t hart, const NemuDiffHypervisorState *state);
  int (*get_state)(uint32_t hart, NemuDiffHypervisorState *state);
  void (*set_mtime)(uint64_t mtime);
} NemuDiffHypervisorAPI;

typedef const NemuDiffHypervisorAPI *(*NemuDiffHypervisorQuery)(uint32_t version,
                                                                uint32_t size);

#endif

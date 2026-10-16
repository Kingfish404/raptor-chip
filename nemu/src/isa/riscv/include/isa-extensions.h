#ifndef NEMU_RISCV_ISA_EXTENSIONS_H
#define NEMU_RISCV_ISA_EXTENSIONS_H

#include <stdbool.h>
#include <difftest-isa.h>

#define RISCV_ENVCFG_PMM (UINT64_C(3) << 32)

extern uint64_t riscv_isa_extensions;
extern bool riscv_isa_locked;
uint64_t riscv_isa_supported(void);
int riscv_isa_configure(uint64_t extensions);
int riscv_isa_configure_names(const char *names);
bool riscv_isa_profile_clock_supported(bool threaded);
void riscv_isa_lock(void);
uint64_t riscv_envcfg_pmm(uint64_t value, uint64_t extension);

static inline bool riscv_sscofpmf_enabled(void)
{
  return (riscv_isa_extensions & NEMU_ISA_EXT_SSCOFPMF) != 0;
}

static inline bool riscv_v128_preview_enabled(void)
{
  return (riscv_isa_extensions & NEMU_ISA_EXT_V128_PREVIEW) != 0;
}

static inline bool riscv_zvbb_enabled(void)
{
  return (riscv_isa_extensions & NEMU_ISA_EXT_ZVBB) != 0;
}

static inline bool riscv_zvfhmin_enabled(void)
{
  return (riscv_isa_extensions & NEMU_ISA_EXT_ZVFHMIN) != 0;
}

static inline bool riscv_smstateen_preview_enabled(void)
{
  return (riscv_isa_extensions & NEMU_ISA_EXT_SMSTATEEN_PREVIEW) != 0;
}

static inline bool riscv_h_gstage_preview_enabled(void)
{
  return (riscv_isa_extensions & NEMU_ISA_EXT_H_GSTAGE_PREVIEW) != 0;
}

static inline uint64_t riscv_supervisor_irq_mask(void)
{
  return UINT64_C(0x222) | (riscv_sscofpmf_enabled() ? UINT64_C(0x2000) : 0);
}

static inline uint64_t riscv_virtual_irq_mask(void)
{
  return riscv_h_gstage_preview_enabled() ? UINT64_C(0x444) : 0;
}

#endif

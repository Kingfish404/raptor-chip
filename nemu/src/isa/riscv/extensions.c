#include <common.h>
#include <isa-extensions.h>

uint64_t riscv_isa_extensions;
bool riscv_isa_locked;

uint64_t riscv_isa_supported(void)
{
  uint64_t supported = 0;
#ifdef CONFIG_MODE_SYSTEM
  supported |= NEMU_ISA_EXT_ZAWRS;
  supported |= NEMU_ISA_EXT_SSCOFPMF;
  supported |= NEMU_ISA_EXT_V128_PREVIEW;
  supported |= NEMU_ISA_EXT_ZVBB;
  supported |= NEMU_ISA_EXT_SMSTATEEN_PREVIEW;
#ifdef CONFIG_RV_F
  supported |= NEMU_ISA_EXT_ZVFHMIN;
#endif
#ifdef CONFIG_RV64
  supported |= NEMU_ISA_EXT_SVNAPOT | NEMU_ISA_EXT_SSNPM | NEMU_ISA_EXT_SMNPM;
  supported |= NEMU_ISA_EXT_H_GSTAGE_PREVIEW;
#endif
#ifdef CONFIG_RV_F
  supported |= NEMU_ISA_EXT_ZFA;
#endif
#endif
  return supported;
}

int riscv_isa_configure(uint64_t extensions)
{
  if (riscv_isa_locked || (extensions & ~riscv_isa_supported()) ||
      ((extensions & (NEMU_ISA_EXT_ZVBB | NEMU_ISA_EXT_ZVFHMIN)) &&
       !(extensions & NEMU_ISA_EXT_V128_PREVIEW)))
    return -1;
  riscv_isa_extensions = extensions;
  return 0;
}

void riscv_isa_lock(void)
{
  riscv_isa_locked = true;
}

bool riscv_isa_profile_clock_supported(bool threaded)
{
  return ISDEF(CONFIG_TIMER_CYCLE) && !threaded;
}

int riscv_isa_configure_names(const char *names)
{
  if (!names) return -1;
  if (!strcmp(names, "none")) return riscv_isa_configure(0);
#if defined(CONFIG_RV64) && defined(CONFIG_MODE_SYSTEM) && defined(CONFIG_RV_F) && \
    defined(CONFIG_RV_D) && defined(CONFIG_RV_SVADE) && !defined(CONFIG_RVE)
  if (!strcmp(names, "rva23") && riscv_isa_supported() && riscv_isa_profile_clock_supported(false))
    return riscv_isa_configure(riscv_isa_supported());
#endif
  return -1;
}

uint64_t riscv_envcfg_pmm(uint64_t value, uint64_t extension)
{
  if (!(riscv_isa_extensions & extension) || ((value >> 32) & 3) == 1) return 0;
  return value & RISCV_ENVCFG_PMM;
}

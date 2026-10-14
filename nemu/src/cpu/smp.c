#include <isa.h>
#include <cpu/cpu.h>
#include <cpu/multidiff.h>
#include <memory/tlb.h>

#ifdef NEMU_HAS_SMP
CPU_state cpu_harts[NEMU_MAX_HARTS];
NEMU_TLS CPU_state *cpu_current = &cpu_harts[0];
unsigned nemu_nr_harts = 1;
NEMU_TLS unsigned nemu_hartid = 0;
bool nemu_hart_waiting[NEMU_MAX_HARTS];

extern NEMU_TLS uint64_t g_nr_guest_inst;
void pmp_hart_switch(void);
void clint_update_mip(void);
bool clint_wfi_advance(void);
void device_update_slow(void);

void cpu_select_hart(unsigned hartid)
{
  assert(hartid < nemu_nr_harts);
  if (hartid == nemu_hartid)
    return;
  nemu_hartid = hartid;
  cpu_current = &cpu_harts[hartid];
  pmp_hart_switch();
  soft_tlb_flush();
}

bool cpu_schedule(void)
{
  static unsigned budget = 255;
  if (budget && !nemu_hart_waiting[nemu_hartid])
  {
    budget--;
    return true;
  }
  for (;;)
  {
    clint_update_mip();
    unsigned previous = nemu_hartid;
    for (unsigned offset = 1; offset <= nemu_nr_harts; offset++)
    {
      unsigned candidate = (previous + offset) % nemu_nr_harts;
      cpu_select_hart(candidate);
      if (!nemu_hart_waiting[candidate] || (riscv_mip_value() & cpu.sr[CSR_MIE]))
      {
        nemu_hart_waiting[candidate] = false;
        budget = 255;
        return true;
      }
    }
    if (!clint_wfi_advance())
      g_nr_guest_inst += 1024;
    if (!multidiff_active()) device_update_slow();
    if (nemu_state.state != NEMU_RUNNING)
      return false;
  }
}

void cpu_invalidate_reservations(paddr_t addr, size_t len)
{
  for (unsigned hartid = 0; hartid < nemu_nr_harts; hartid++)
  {
    CPU_state *hart = riscv_hart(hartid);
    if (hart->reservation_bytes && len &&
        (addr >= hart->reservation ? addr - hart->reservation < hart->reservation_bytes
                                  : hart->reservation - addr < len))
    {
      hart->reservation = 0;
      hart->reservation_bytes = 0;
    }
  }
}
#endif

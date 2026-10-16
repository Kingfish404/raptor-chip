#include <cpu/multidiff.h>
#include <cpu/diffjournal.h>
#include <cpu/replay.h>
#include <difftest-journal.h>

#if defined(CONFIG_ISA_riscv) && defined(CONFIG_MODE_SYSTEM) && !defined(CONFIG_TARGET_AM)
#include <isa.h>
#include <isa-extensions.h>
#include <cpu/cpu.h>
#include <memory/paddr.h>
#include <memory/tlb.h>
#include <cpu/icache.h>

bool nemu_md_enabled;
bool nemu_md_interrupts;
bool nemu_md_clint;
bool nemu_md_plic;
bool nemu_md_uart;
bool nemu_md_rng;
bool nemu_md_net;
bool nemu_md_block;
bool nemu_md_tlb_retain;

_Static_assert(SOFT_TLB_BITS == NEMU_JOURNAL_TLB_BITS, "journal TLB geometry changed");
_Static_assert(sizeof(NemuDiffState) == (1 + 32 + 32 + 4096 + 2) * sizeof(uint64_t) +
               4 * sizeof(uint32_t), "capture state layout must have no padding");
unsigned nemu_md_harts;
NEMU_TLS NemuDiffFrame nemu_md_frame;
void (*nemu_md_invalidate)(paddr_t address, int size);

bool nemu_md_active(void)
{
  return nemu_md_enabled;
}

bool nemu_md_clint_active(void)
{
  return nemu_md_enabled && nemu_md_clint;
}

bool nemu_md_plic_active(void)
{
  return nemu_md_enabled && nemu_md_plic;
}

bool nemu_md_uart_active(void)
{
  return nemu_md_enabled && nemu_md_uart;
}

bool nemu_md_uart_span(paddr_t address, int size)
{
  return nemu_md_uart_active() && size == 1 && address >= NEMU_JOURNAL_UART_BASE &&
      address - NEMU_JOURNAL_UART_BASE < 8;
}

bool nemu_md_rng_active(void)
{
  return nemu_md_enabled && nemu_md_rng;
}

bool nemu_md_rng_span(paddr_t address, int size)
{
  return nemu_md_rng_active() && size == 4 && !(address % 4) &&
      address >= NEMU_JOURNAL_RNG_BASE && address - NEMU_JOURNAL_RNG_BASE < 4096;
}

bool nemu_md_net_active(void)
{
  return nemu_md_enabled && nemu_md_net;
}

bool nemu_md_net_span(paddr_t address, int size, bool write)
{
  if (!nemu_md_net_active() || address < NEMU_JOURNAL_NET_BASE ||
      address - NEMU_JOURNAL_NET_BASE >= 4096) return false;
  if (size == 4 && !(address % 4)) return true;
  return !write && (size == 1 || size == 2) && !(address % size) &&
      address >= NEMU_JOURNAL_NET_BASE + 0x100 && address + size <= NEMU_JOURNAL_NET_BASE + 0x108;
}

bool nemu_md_block_active(void)
{
  return nemu_md_enabled && nemu_md_block;
}

bool nemu_md_block_span(paddr_t address, int size)
{
  return nemu_md_block_active() && address >= NEMU_JOURNAL_BLOCK_BASE &&
      address - NEMU_JOURNAL_BLOCK_BASE < 4096 && size == 4 && !(address % 4);
}

bool nemu_md_plic_span(paddr_t address, int size)
{
  if (!nemu_md_plic_active() || size != 4 || address % 4 || address < NEMU_JOURNAL_PLIC_BASE)
    return false;
  uint64_t offset = address - NEMU_JOURNAL_PLIC_BASE;
  return offset < 33 * 4 || (offset >= 0x1000 && offset < 0x1008) ||
      (offset >= 0x2000 && offset < 0x2000 + 2 * nemu_md_harts * 0x80 && (offset - 0x2000) % 0x80 < 8) ||
      (offset >= 0x200000 && offset < 0x200000 + 2 * nemu_md_harts * 0x1000 && (offset - 0x200000) % 0x1000 < 8);
}

bool nemu_md_clint_span(paddr_t address, int size, bool write)
{
  if (!nemu_md_clint_active() || (size != 4 && size != 8) || size > sizeof(word_t) || address % size)
    return false;
  uint64_t offset = address - NEMU_JOURNAL_CLINT_BASE;
  if (address < NEMU_JOURNAL_CLINT_BASE || offset >= 0xc000) return false;
  return (size == 4 && offset < 4ull * nemu_md_harts) ||
      (offset >= 0x4000 && offset + size <= 0x4000 + 8ull * nemu_md_harts) ||
      (!write && offset >= 0xbff8 && offset + size <= 0xc000);
}

uint64_t nemu_md_features(void)
{
  uint64_t geometry = 0;
#ifdef CONFIG_RV64
  geometry = ((uint64_t)CONFIG_RV_ASID_BITS << 32) | ((uint64_t)CONFIG_RV_PMPADDR_BITS << 16);
#endif
  return geometry |
         NEMU_ISA_JOURNAL_ENCODE(riscv_isa_extensions) |
         (ISDEF(CONFIG_RV_F) << 0) | (ISDEF(CONFIG_RV_D) << 1) |
         (ISDEF(CONFIG_RV_SVADE) << 2) | (ISDEF(CONFIG_RV_MCOUNTINHIBIT) << 3) |
         (ISDEF(CONFIG_RV_EBREAK_HOST_EXIT) << 4) | (ISDEF(CONFIG_RAPTOR_MEMORY_MAP) << 5) |
         (ISDEF(CONFIG_RVE) << 6) | (ISDEF(CONFIG_RV_RVA22S64) << 7);
}

void nemu_md_capture(NemuDiffState *state)
{
  state->pc = cpu.pc;
  for (unsigned index = RISCV_GPR_NUM; index < 32; index++) state->gpr[index] = 0;
#ifdef CONFIG_RV64
  memcpy(state->gpr, cpu.gpr, sizeof(cpu.gpr));
  memcpy(state->csr, cpu.sr, sizeof(state->csr));
#else
  for (unsigned index = 0; index < RISCV_GPR_NUM; index++) state->gpr[index] = cpu.gpr[index];
  for (unsigned index = 0; index < 4096; index++) state->csr[index] = cpu.sr[index];
#endif
  memcpy(state->fpr, cpu.fpr, sizeof(state->fpr));
  state->privilege = cpu.priv | (cpu.virt ? 4u : 0u);
  state->reservation = cpu.reservation;
  state->reservation_bytes = cpu.reservation_bytes;
  state->mtimecmp = cpu.mtimecmp;
  state->stip = cpu.stip;
  state->seip = cpu.seip;
}

void nemu_md_restore(const NemuDiffState *state)
{
  memset(&cpu, 0, sizeof(cpu));
  cpu.pc = state->pc;
  for (unsigned index = 0; index < RISCV_GPR_NUM; index++) cpu.gpr[index] = state->gpr[index];
  memcpy(cpu.fpr, state->fpr, sizeof(cpu.fpr));
  for (unsigned index = 0; index < 4096; index++) cpu.sr[index] = state->csr[index];
  cpu.priv = state->privilege & 3u;
  cpu.virt = riscv_h_gstage_preview_enabled() && (state->privilege & 4u) != 0;
  cpu.reservation = state->reservation;
  cpu.reservation_bytes = state->reservation_bytes;
  cpu.mtimecmp = state->mtimecmp;
  cpu.stip = state->stip;
  cpu.seip = state->seip;
  cpu.raise_intr = INTR_EMPTY;
  cpu.last_inst_priv = cpu.priv;
  pmp_hart_switch();
  soft_tlb_flush();
}

void nemu_md_reset_frame(void)
{
  size_t offset = offsetof(NemuDiffFrame, memory);
  memset((uint8_t *)&nemu_md_frame + offset, 0, sizeof(nemu_md_frame) - offset);
  if (nemu_md_tlb_retain) icache_flush();
  else soft_tlb_flush();
}

void nemu_md_record(paddr_t address, int size, bool write, word_t data)
{
  if (!nemu_md_enabled) return;
  if (nemu_md_frame.count == NEMU_DIFF_MULTI_EVENTS) {
    nemu_md_frame.error = 1;
    return;
  }
  NemuDiffMemory *event = &nemu_md_frame.memory[nemu_md_frame.count++];
  event->address = address;
  event->size = size;
  event->write = write;
  event->data = (uint64_t)data & (UINT64_MAX >> ((8 - size) * 8));
  if (nemu_journal_memory) nemu_journal_memory(address, size, write, data);
}

bool nemu_md_guard(paddr_t address, int size, bool write, word_t data)
{
  if (!nemu_md_enabled) return true;
  IFDEF(NEMU_HAS_REPLAY, if (nemu_replay_access) nemu_replay_access(address, size, write, data));
  if (write && address == 0x100000 && size == 4 && data == 0x5555) {
    nemu_md_record(address, size, write, data);
    set_nemu_state(NEMU_END, cpu.pc, 0);
    return false;
  }
  bool io = nemu_md_clint_span(address, size, write) || nemu_md_plic_span(address, size) ||
      nemu_md_uart_span(address, size) || nemu_md_rng_span(address, size) || nemu_md_net_span(address, size, write) ||
      nemu_md_block_span(address, size);
  bool finisher_read = !write && address == 0x100000 && size == 4;
  bool valid = finisher_read || io || (size > 0 && size <= 8 &&
      ((address >= PMEM_LEFT && address - PMEM_LEFT < CONFIG_MSIZE &&
        (uint64_t)size <= CONFIG_MSIZE - (address - PMEM_LEFT)) ||
       (!write && in_rom(address) && (uint64_t)size <= CONFIG_ROM_SIZE - (address - CONFIG_ROM_BASE))));
  if (!valid) {
    fprintf(stderr, "NEMU_MULTIDIFF_UNSUPPORTED hart=%" PRIu64 " pc=0x%" PRIx64
            " address=0x%" PRIx64 " size=%d write=%u data=0x%" PRIx64 "\n",
            (uint64_t)cpu.sr[CSR_MHARTID], (uint64_t)cpu.pc, (uint64_t)address,
            size, (unsigned)write, (uint64_t)data);
    nemu_md_frame.error = 1;
    return false;
  }
  IFDEF(NEMU_HAS_SMP, if (io && nemu_journal_io) nemu_journal_io(address, size, write, data));
  if (write && !io && nemu_md_invalidate) nemu_md_invalidate(address, size);
  return true;
}

bool nemu_md_dma_guard(paddr_t address, size_t size, bool write)
{
  if (!nemu_md_enabled) return true;
  if (nemu_md_rng && nemu_journal_dma_scope && nemu_journal_dma_scope()) return true;
  fprintf(stderr, "NEMU_MULTIDIFF_UNSUPPORTED_DMA hart=%" PRIu64 " pc=0x%" PRIx64
          " address=0x%" PRIx64 " size=%zu write=%u\n",
          (uint64_t)cpu.sr[CSR_MHARTID], (uint64_t)cpu.pc,
          (uint64_t)address, size, (unsigned)write);
  nemu_md_frame.error = 1;
  set_nemu_state(NEMU_ABORT, cpu.pc, 1);
  return false;
}

bool nemu_md_instruction(uint32_t instruction)
{
  if (!nemu_md_enabled) return true;
  unsigned csr = instruction >> 20;
  if ((instruction == 0x10500073 && !nemu_md_interrupts) ||
      (!nemu_md_clint && (instruction & 0x7f) == 0x73 && (instruction & 0x7000) &&
       (csr == CSR_TIME || csr == CSR_TIMEH))) {
    nemu_md_frame.error = 1;
    set_nemu_state(NEMU_ABORT, cpu.pc, 1);
    return false;
  }
  return true;
}
#endif

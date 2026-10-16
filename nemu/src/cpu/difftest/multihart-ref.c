#include <cpu/multidiff.h>
#include <difftest-vector.h>

#if defined(CONFIG_ISA_riscv) && defined(CONFIG_TARGET_SHARE) && defined(CONFIG_MODE_SYSTEM)
#include <isa.h>
#include <memory/paddr.h>
#include <utils.h>

static NemuDiffState states[NEMU_DIFF_MULTI_HARTS];
static NemuDiffVectorState vector_states[NEMU_DIFF_MULTI_HARTS];
static unsigned hart_count;
static uint64_t next_sequence;
static bool stopped;
extern NEMU_TLS uint64_t g_nr_guest_inst;

static void invalidate(paddr_t address, int size)
{
  if (cpu.reservation_bytes &&
      (address >= cpu.reservation ? address - cpu.reservation < cpu.reservation_bytes
                                  : cpu.reservation - address < size)) {
    cpu.reservation = 0;
    cpu.reservation_bytes = 0;
  }
  for (unsigned hart = 0; hart < hart_count; hart++) {
    NemuDiffState *state = &states[hart];
    if (state->reservation_bytes &&
        (address >= state->reservation ? address - state->reservation < state->reservation_bytes
                                       : state->reservation - address < size)) {
      state->reservation = 0;
      state->reservation_bytes = 0;
    }
  }
}

static int initialize(uint32_t harts)
{
  if (!harts || harts > NEMU_DIFF_MULTI_HARTS || hart_count) return -1;
  void init_mem(void);
  init_mem();
  memset(guest_to_host(PMEM_LEFT), 0, CONFIG_MSIZE);
  memset(&cpu, 0, sizeof(cpu));
  init_isa();
  hart_count = harts;
  for (unsigned hart = 0; hart < hart_count; hart++) {
    cpu.sr[CSR_MHARTID] = hart;
    nemu_md_capture(&states[hart]);
  }
  nemu_md_invalidate = invalidate;
  nemu_md_enabled = true;
  return 0;
}

static int set_state(uint32_t hart, const NemuDiffState *state)
{
  if (hart >= hart_count || !state || next_sequence || state->gpr[0] ||
      state->csr[CSR_MHARTID] != hart || (state->privilege & 3) == 2 ||
      ((state->privilege & 3) == 3 && (state->privilege & 4)) ||
      state->privilege > (riscv_h_gstage_preview_enabled() ? 5u : 3u) ||
      state->reservation_bytes || state->stip > 1 || state->seip > 1) return -1;
#ifndef CONFIG_RV64
  if (state->pc > UINT32_MAX) return -1;
  for (unsigned index = 0; index < 32; index++)
    if (state->gpr[index] > UINT32_MAX) return -1;
  for (unsigned index = 0; index < 4096; index++)
    if (state->csr[index] > UINT32_MAX) return -1;
#endif
  states[hart] = *state;
  return 0;
}

static int get_state(uint32_t hart, NemuDiffState *state)
{
  if (hart >= hart_count || !state) return -1;
  *state = states[hart];
  return 0;
}

static int set_vector_state(uint32_t hart, const NemuDiffVectorState *state)
{
  if (!state || next_sequence) return -1;
  if (!hart_count)
  {
    if (hart) return -1;
    memcpy(cpu.vreg, state->reg, sizeof(cpu.vreg));
    return 0;
  }
  if (hart >= hart_count) return -1;
  vector_states[hart] = *state;
  return 0;
}

static int get_vector_state(uint32_t hart, NemuDiffVectorState *state)
{
  if (!state) return -1;
  if (!hart_count)
  {
    if (hart) return -1;
    memcpy(state->reg, cpu.vreg, sizeof(cpu.vreg));
    return 0;
  }
  if (hart >= hart_count) return -1;
  *state = vector_states[hart];
  return 0;
}

static int memory_copy(uint64_t address, void *buffer, size_t size, uint32_t to_ref)
{
  if (!hart_count || !buffer || !size || to_ref > 1 || (to_ref && next_sequence)) return -1;
  bool ram = address >= PMEM_LEFT && address - PMEM_LEFT < CONFIG_MSIZE &&
      size <= CONFIG_MSIZE - (address - PMEM_LEFT);
  bool rom = address >= CONFIG_ROM_BASE && address - CONFIG_ROM_BASE < CONFIG_ROM_SIZE &&
      size <= CONFIG_ROM_SIZE - (address - CONFIG_ROM_BASE) && in_rom(address);
  if (!ram && !rom) return -1;
  if (to_ref) memcpy(guest_to_host(address), buffer, size);
  else memcpy(buffer, guest_to_host(address), size);
  return 0;
}

static int step(uint32_t hart, uint64_t sequence, NemuDiffFrame *frame)
{
  if (hart >= hart_count || !frame || sequence != next_sequence || stopped) return -1;
  nemu_md_restore(&states[hart]);
  memcpy(cpu.vreg, vector_states[hart].reg, sizeof(cpu.vreg));
  nemu_md_reset_frame();
  g_nr_guest_inst = sequence;
  nemu_state.state = NEMU_RUNNING;
  if (riscv_intr_may_pending()) nemu_md_frame.error = 1;
  else nemu_md_exec_one();
  nemu_md_capture(&states[hart]);
  memcpy(vector_states[hart].reg, cpu.vreg, sizeof(cpu.vreg));
  nemu_md_frame.state = states[hart];
  nemu_md_frame.trapped = cpu.instruction_trapped;
  nemu_md_frame.ended = nemu_state.state == NEMU_END;
  if (nemu_state.state == NEMU_ABORT) nemu_md_frame.error = 1;
  stopped = nemu_md_frame.error || nemu_md_frame.ended;
  *frame = nemu_md_frame;
  next_sequence++;
  return frame->error ? -1 : 0;
}

__EXPORT const NemuDiffAPI *nemu_difftest_query(uint32_t version, uint32_t size)
{
  static NemuDiffAPI api = {
    .version = NEMU_DIFF_MULTI_VERSION, .size = sizeof(NemuDiffAPI),
    .xlen = XLEN, .max_harts = NEMU_DIFF_MULTI_HARTS,
    .capabilities = NEMU_DIFF_MULTI_STRICT_MEMORY,
    .ram_base = CONFIG_MBASE, .ram_size = CONFIG_MSIZE,
    .init = initialize, .set_state = set_state, .get_state = get_state,
    .memory_copy = memory_copy, .step = step,
  };
  if (version != api.version || size != api.size) return NULL;
  api.isa_features = nemu_md_features();
  return &api;
}

__EXPORT const NemuDiffVectorAPI *nemu_difftest_vector_query(uint32_t version, uint32_t size)
{
  static const NemuDiffVectorAPI api = {
    .version = NEMU_DIFF_VECTOR_VERSION, .size = sizeof(NemuDiffVectorAPI),
    .xlen = XLEN, .max_harts = NEMU_DIFF_MULTI_HARTS,
    .set_state = set_vector_state, .get_state = get_vector_state,
  };
  return version == api.version && size == api.size ? &api : NULL;
}
#endif

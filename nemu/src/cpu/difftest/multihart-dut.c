#include <cpu/multidiff.h>
#include <difftest-vector.h>

#ifdef NEMU_HAS_SMP
#include <cpu/cpu.h>
#include <isa.h>
#include <isa-extensions.h>
#include <memory/paddr.h>
#include <utils.h>
#include <dlfcn.h>

bool nemu_multidiff_requested;
static const NemuDiffAPI *reference;
static const NemuDiffVectorAPI *vector_reference;
static uint64_t sequence;
static uint64_t start_pc;
static unsigned seen_harts;
static NemuDiffFrame expected;

static void require(bool condition, const char *message)
{
  if (!condition) {
    fprintf(stderr, "NEMU multihart DiffTest: %s\n", message);
    exit(EXIT_FAILURE);
  }
}

static void mismatch(const char *field, unsigned index, uint64_t actual, uint64_t wanted)
{
  fprintf(stderr, "NEMU_MULTIDIFF_FAIL hart=%u sequence=%" PRIu64 " pc=0x%" PRIx64
          " %s[%u] dut=0x%" PRIx64 " ref=0x%" PRIx64 "\n",
          nemu_hartid, sequence, start_pc, field, index, actual, wanted);
  nemu_state.halt_pc = start_pc;
  nemu_state.halt_ret = 1;
  nemu_state.state = NEMU_ABORT;
}

void nemu_multidiff_init(const char *path, size_t image_size)
{
  require(path != NULL, "--diff-mode=multihart requires --diff=REF_SO");
  void *handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
  require(handle != NULL, "cannot load reference library");
  if (riscv_isa_extensions) {
    NemuISAQuery isa_query = (NemuISAQuery)dlsym(handle, "nemu_difftest_isa_query");
    const NemuISAAPI *isa_api = isa_query ? isa_query(NEMU_ISA_API_VERSION, sizeof(NemuISAAPI)) : NULL;
    require(isa_api && isa_api->version == NEMU_ISA_API_VERSION && isa_api->size == sizeof(NemuISAAPI)
            && isa_api->xlen == XLEN && isa_api->configure && !isa_api->locked
            && !(riscv_isa_extensions & ~isa_api->supported), "reference lacks requested ISA extensions");
    require(isa_api->configure(riscv_isa_extensions) == 0, "reference ISA configuration failed");
  }
  NemuDiffQuery query = (NemuDiffQuery)dlsym(handle, "nemu_difftest_query");
  require(query != NULL, "reference lacks the versioned multihart ABI");
  reference = query(NEMU_DIFF_MULTI_VERSION, sizeof(NemuDiffAPI));
  require(reference && reference->version == NEMU_DIFF_MULTI_VERSION &&
          reference->size == sizeof(NemuDiffAPI), "reference ABI version/size mismatch");
  require(reference->xlen == XLEN && reference->max_harts >= nemu_nr_harts &&
          reference->isa_features == nemu_md_features(), "reference ISA/hart capability mismatch");
  require((reference->capabilities & NEMU_DIFF_MULTI_STRICT_MEMORY) &&
          reference->ram_base == PMEM_LEFT && reference->ram_size == CONFIG_MSIZE,
          "reference memory capability/map mismatch");
  require(reference->init && reference->set_state && reference->get_state &&
          reference->memory_copy && reference->step, "incomplete reference API");
  if (riscv_v128_preview_enabled()) {
    NemuDiffVectorQuery vector_query = (NemuDiffVectorQuery)dlsym(handle, "nemu_difftest_vector_query");
    vector_reference = vector_query ? vector_query(NEMU_DIFF_VECTOR_VERSION, sizeof(NemuDiffVectorAPI)) : NULL;
    require(vector_reference && vector_reference->version == NEMU_DIFF_VECTOR_VERSION &&
            vector_reference->size == sizeof(NemuDiffVectorAPI) && vector_reference->xlen == XLEN &&
            vector_reference->max_harts >= nemu_nr_harts && vector_reference->set_state &&
            vector_reference->get_state, "reference lacks vector register state API");
  }
  require(image_size <= CONFIG_MSIZE, "image exceeds RAM");
  require(reference->init(nemu_nr_harts) == 0, "reference initialization failed");
  require(reference->memory_copy(PMEM_LEFT, guest_to_host(PMEM_LEFT), CONFIG_MSIZE, 1) == 0,
          "reference RAM initialization failed");
  if (in_rom(CONFIG_ROM_BASE))
    require(reference->memory_copy(CONFIG_ROM_BASE, guest_to_host(CONFIG_ROM_BASE), CONFIG_ROM_SIZE, 1) == 0,
            "reference ROM initialization failed");
  for (unsigned hart = 0; hart < nemu_nr_harts; hart++) {
    cpu_select_hart(hart);
    nemu_md_capture(&nemu_md_frame.state);
    require(reference->set_state(hart, &nemu_md_frame.state) == 0, "reference hart initialization failed");
    if (vector_reference) {
      NemuDiffVectorState vector_state;
      NemuDiffVectorState observed;
      memcpy(vector_state.reg, cpu.vreg, sizeof(cpu.vreg));
      require(vector_reference->set_state(hart, &vector_state) == 0,
              "reference vector hart initialization failed");
      require(vector_reference->get_state(hart, &observed) == 0 &&
              memcmp(&observed, &vector_state, sizeof(vector_state)) == 0,
              "reference initial vector state mismatch");
    }
    require(reference->get_state(hart, &expected.state) == 0 &&
            memcmp(&expected.state, &nemu_md_frame.state, sizeof(NemuDiffState)) == 0,
            "reference initial state mismatch");
  }
  cpu_select_hart(0);
  nemu_md_enabled = true;
  printf("NEMU_MULTIDIFF enabled harts=%u abi=%u mode=rr-strict\n", nemu_nr_harts, NEMU_DIFF_MULTI_VERSION);
}

bool nemu_multidiff_begin(void)
{
  if (!nemu_multidiff_requested) return true;
  start_pc = cpu.pc;
  nemu_md_reset_frame();
  if (riscv_intr_may_pending()) {
    mismatch("unsupported-interrupt", 0, riscv_mip_value(), 0);
    return false;
  }
  return true;
}

static bool compare_words(const char *field, const uint64_t *actual, const uint64_t *wanted, unsigned count)
{
  for (unsigned index = 0; index < count; index++) {
    if (actual[index] != wanted[index]) {
      mismatch(field, index, actual[index], wanted[index]);
      return false;
    }
  }
  return true;
}

void nemu_multidiff_finish(void)
{
  if (!nemu_multidiff_requested) return;
  if (nemu_md_frame.error) {
    mismatch("unsupported-event-or-overflow", 0, nemu_md_frame.error, 0);
    return;
  }
  nemu_md_capture(&nemu_md_frame.state);
  nemu_md_frame.trapped = cpu.instruction_trapped;
  nemu_md_frame.ended = nemu_state.state == NEMU_END;
  memset(&expected, 0, sizeof(expected));
  if (reference->step(nemu_hartid, sequence, &expected) != 0 || expected.error) {
    mismatch("reference-step", 0, 0, expected.error);
    return;
  }
  NemuDiffState *actual = &nemu_md_frame.state;
  NemuDiffState *wanted = &expected.state;
  if (!compare_words("pc", &actual->pc, &wanted->pc, 1) ||
      !compare_words("gpr", actual->gpr, wanted->gpr, 32) ||
      !compare_words("fpr", actual->fpr, wanted->fpr, 32) ||
      !compare_words("csr", actual->csr, wanted->csr, 4096)) return;
  if (memcmp(actual, wanted, sizeof(*actual))) {
    mismatch("privilege-reservation-or-platform-state", 0, actual->privilege, wanted->privilege);
    return;
  }
  if (vector_reference) {
    NemuDiffVectorState vector_state;
    if (vector_reference->get_state(nemu_hartid, &vector_state) != 0) {
      mismatch("vreg-state", 0, 0, 1);
      return;
    }
    for (unsigned reg = 0; reg < 32; reg++)
      for (unsigned byte = 0; byte < NEMU_DIFF_VECTOR_VLENB; byte++)
        if (cpu.vreg[reg][byte] != vector_state.reg[reg][byte]) {
          mismatch("vreg-byte", reg * NEMU_DIFF_VECTOR_VLENB + byte,
                   cpu.vreg[reg][byte], vector_state.reg[reg][byte]);
          return;
        }
  }
  if (nemu_md_frame.trapped != expected.trapped || nemu_md_frame.ended != expected.ended) {
    mismatch("trap-or-end", 0, nemu_md_frame.trapped, expected.trapped);
    return;
  }
  if (nemu_md_frame.count != expected.count) {
    mismatch("memory-count", 0, nemu_md_frame.count, expected.count);
    return;
  }
  for (unsigned index = 0; index < expected.count; index++) {
    if (memcmp(&nemu_md_frame.memory[index], &expected.memory[index], sizeof(NemuDiffMemory))) {
      NemuDiffMemory *actual_event = &nemu_md_frame.memory[index];
      NemuDiffMemory *expected_event = &expected.memory[index];
      fprintf(stderr, "  memory dut=(0x%" PRIx64 ",%u,%u) ref=(0x%" PRIx64 ",%u,%u) address,size,write\n",
              actual_event->address, actual_event->size, actual_event->write,
              expected_event->address, expected_event->size, expected_event->write);
      mismatch("memory-event", index, nemu_md_frame.memory[index].data, expected.memory[index].data);
      return;
    }
  }
  sequence++;
  seen_harts |= 1u << nemu_hartid;
}

void nemu_multidiff_report(void)
{
  if (nemu_multidiff_requested)
    printf("NEMU_MULTIDIFF checked=%" PRIu64 " harts=%u seen=0x%x status=%s\n",
           sequence, nemu_nr_harts, seen_harts, nemu_state.state == NEMU_ABORT ? "FAIL" : "OK");
}
#endif

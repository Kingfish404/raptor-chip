#include <common.h>
#include <cpu.h>
#include <checkpoint.h>
#include <memory.h>
#include <difftest-isa.h>
#include <difftest-hypervisor.h>
#include <difftest-vector.h>
#include <dlfcn.h>
#ifdef RAPT_LARGE_PMEM
#include <sys/mman.h>
#include <unistd.h>
#include <vector>
#endif

extern NPCState npc;
extern char *regs[];


void (*ref_difftest_memcpy)(paddr_t addr, void *buf, size_t n, bool direction) = NULL;
#ifdef RAPT_LARGE_PMEM
static void (*ref_difftest_reset_pmem)(void) = NULL;

static void difftest_sync_sparse_pmem()
{
  constexpr size_t chunk = 64 * 1024;
  static const uint8_t zeros[chunk] = {};
  uint8_t *pmem = guest_to_host(MBASE);
  assert(pmem != nullptr && ref_difftest_reset_pmem != nullptr);
  const long page_size = sysconf(_SC_PAGESIZE);
  assert(page_size > 0);
  std::vector<unsigned char> resident((MSIZE + (size_t)page_size - 1) / (size_t)page_size);
  assert(mincore(pmem, MSIZE, resident.data()) == 0);
  ref_difftest_reset_pmem();
  for (size_t off = 0; off < MSIZE; off += chunk)
  {
    const size_t n = off + chunk <= MSIZE ? chunk : MSIZE - off;
    bool any_resident = false;
    for (size_t page = off / (size_t)page_size;
         page <= (off + n - 1) / (size_t)page_size; ++page)
      any_resident |= (resident[page] & 1u) != 0;
    if (!any_resident) continue;
    if (memcmp(pmem + off, zeros, n) != 0)
      ref_difftest_memcpy((paddr_t)((uint64_t)MBASE + off), pmem + off, n, DIFFTEST_TO_REF);
  }
}
#endif
void (*ref_difftest_regcpy)(void *dut, bool direction) = NULL;
void (*ref_difftest_exec)(uint64_t n) = NULL;
void (*ref_difftest_raise_intr)(uint64_t NO) = NULL;
uint32_t (*ref_difftest_state_version)(void) = NULL;
void (*ref_difftest_set_meip)(uint8_t val) = NULL;
void (*ref_difftest_set_msip)(uint8_t val) = NULL;
void (*ref_difftest_set_mtip)(uint8_t val) = NULL;
void (*ref_difftest_set_stip)(uint8_t val) = NULL;
void (*ref_difftest_set_seip)(uint8_t val) = NULL;
void (*ref_difftest_plic_raise)(uint32_t src) = NULL;
static void (*ref_difftest_checkpoint_sync)(void *dut, uint32_t plic_ndev,
                                            uint32_t plic_nctx) = NULL;
static void (*ref_difftest_clear_reservation)(void) = NULL;
static void (*ref_difftest_restore_sstc)(uint64_t, uint64_t) = NULL;
static const NemuDiffVectorAPI *vector_reference = nullptr;
static const NemuDiffVectorCSRAPI *vector_csr_reference = nullptr;
const NemuDiffHypervisorAPI *hypervisor_reference = nullptr;

static void sync_hypervisor_reference()
{
  if (npc.hypervisor_csrs == nullptr || hypervisor_reference == nullptr) return;
  NemuDiffHypervisorState state = {};
  state.virt = npc.virt != nullptr ? (*npc.virt & 1u) : 0u;
  state.priv = npc.priv != nullptr ? ((uint8_t)*npc.priv & 3u) : 3u;
  for (unsigned index = 0; index < NEMU_DIFF_HYPERVISOR_CSR_COUNT; index++)
    state.csr[index] = npc.hypervisor_csrs[index];
  if (npc.clint_mtime != nullptr && hypervisor_reference->set_mtime != nullptr)
    hypervisor_reference->set_mtime(*npc.clint_mtime);
  Assert(hypervisor_reference->set_state(0, &state) == 0,
         "Hypervisor reference rejected the CSR state");
}

static void sync_vector_reference()
{
  if (npc.vreg == nullptr) return;
  Assert(vector_reference != nullptr && vector_csr_reference != nullptr,
         "Vector reference APIs are unavailable");
  NemuDiffVectorState registers;
  NemuDiffVectorCSRs csrs;
  memcpy(registers.reg, npc.vreg, sizeof(registers.reg));
  for (unsigned index = 0; index < NEMU_DIFF_VECTOR_CSR_COUNT; index++)
    csrs.value[index] = npc.vector_csrs[index];
  Assert(vector_reference->set_state(0, &registers) == 0,
         "Vector reference rejected the register state");
  Assert(vector_csr_reference->set_state(0, &csrs) == 0,
         "Vector reference rejected the CSR state");
}

static bool is_skip_ref = false;
static bool should_diff_mem = false;
static int skip_dut_nr_inst = 0;
// When `-d <ref.so>` is not supplied, the simulator runs without comparing
// against a reference. This is useful for coverage / pk-based workloads that
// exercise paths the current REF doesn't model identically (e.g. Sv32 paging,
// medeleg-driven exception delegation). Set in init_difftest().
static bool difftest_enabled = false;

static void (*ref_difftest_store_error)(uint64_t, uint8_t) = nullptr;
static void (*ref_difftest_restore_store_error)(uint64_t, uint64_t) = nullptr;
static bool store_error_queued = false;
static uint64_t store_error_addr = 0;
static uint8_t store_error_strb = 0;
extern "C" void npc_store_error_event(uint64_t addr, uint8_t strb)
{
  if (!difftest_enabled) return;
  assert(!store_error_queued);
  store_error_queued = true;
  store_error_addr = addr;
  store_error_strb = strb;
}
void difftest_apply_store_error()
{
  if (!store_error_queued) return;
  assert(difftest_enabled && ref_difftest_store_error != nullptr);
  ref_difftest_store_error(store_error_addr, store_error_strb);
  store_error_queued = false;
}

bool difftest_is_enabled() { return difftest_enabled; }

void difftest_checkpoint_resync()
{
  if (!difftest_enabled)
    return;
  cpu_read_pmpaddr_snapshot();

#ifdef RAPT_LARGE_PMEM
  difftest_sync_sparse_pmem();
#else
  ref_difftest_memcpy(MBASE, guest_to_host(MBASE), MSIZE, DIFFTEST_TO_REF);
#endif
  ref_difftest_memcpy(MROM_BASE, guest_to_host(MROM_BASE), MROM_SIZE, DIFFTEST_TO_REF);
  ref_difftest_memcpy(FLASH_BASE, guest_to_host(FLASH_BASE), FLASH_SIZE, DIFFTEST_TO_REF);
  // Trampoline execution is not replayed by REF. Install its saved timer CSR
  // state before regcpy interprets STCE and the software STIP latch.
  if (ref_difftest_restore_sstc != nullptr)
    ref_difftest_restore_sstc(*npc.menvcfgh, *npc.stimecmp);
  else
    assert(*npc.menvcfgh == 0 && *npc.stimecmp == UINT64_MAX &&
           "checkpoint Sstc state requires a reference with difftest_restore_sstc");
  if (ref_difftest_checkpoint_sync != NULL)
    ref_difftest_checkpoint_sync(&npc, NPC_PLIC_NDEV, NPC_PLIC_NCTX);
  else
    ref_difftest_regcpy(&npc, DIFFTEST_TO_REF);
  sync_vector_reference();
  sync_hypervisor_reference();

  uint64_t error_status = (*npc.bus_error_pending & 1u) |
      ((*npc.bus_error_overflow & 1u) << 1) | ((uint64_t)*npc.bus_error_strb << 8);
  if (ref_difftest_restore_store_error != nullptr)
    ref_difftest_restore_store_error(error_status, *npc.bus_error_addr);
  else
    assert(error_status == 0 && *npc.bus_error_addr == 0);
  // Snapshot state includes all completed errors; a pre-resync queued event
  // must not be applied again as an additional failure.
  store_error_queued = false;
  is_skip_ref = false;
  should_diff_mem = false;
  skip_dut_nr_inst = 0;
  Log("checkpoint: resynchronized difftest REF from restored DUT state");
}

void difftest_should_diff_mem()
{
  should_diff_mem = true;
}

void difftest_skip_ref()
{
  is_skip_ref = true;
}

void difftest_skip_dut(int nr_ref, int nr_dut)
{
  if (!difftest_enabled)
    return;
  skip_dut_nr_inst += nr_dut;

  while (nr_ref-- > 0)
  {
    ref_difftest_exec(1);
  }
}

void difftest_raise_intr(uint64_t NO)
{
  if (!difftest_enabled)
    return;
  ref_difftest_raise_intr(NO);
}

static void checkmem(uint8_t *ref, uint8_t *dut, size_t n) __attribute__((unused));
static void checkmem(uint8_t *ref, uint8_t *dut, size_t n)
{
  ref_difftest_memcpy(MBASE, ref, n, DIFFTEST_TO_DUT);
  for (size_t i = 0; i < n; i++)
  {
    if (ref[i] != dut[i])
    {
      printf(FMT_RED("[ERROR]") " mem[%zx] is different! ref = " FMT_WORD_NO_PREFIX ", dut = " FMT_WORD_NO_PREFIX "\n",
             i, (word_t)ref[i], (word_t)dut[i]);
      printf("mem_dut: ");
      for (int j = 0; j < 16; j++)
      {
        printf("%02x ", dut[i - 8 + j]);
      }
      printf("\n");
      printf("mem_ref: ");
      for (int j = 0; j < 16; j++)
      {
        printf("%02x ", ref[i - 8 + j]);
      }
      printf("\n");
      npc.state = NPC_ABORT;
      return;
    }
  }
}

void init_difftest(char *ref_so_file, long img_size, int port, uint64_t isa_extensions)
{
#ifdef CONFIG_DIFFTEST
  if (ref_so_file == NULL)
  {
    assert(isa_extensions == 0);
    printf("[difftest] DISABLED: no `-d <ref.so>` argument supplied; "
           "register/CSR comparison against REF is skipped.\n");
    difftest_enabled = false;
    return;
  }
  difftest_enabled = true;
  if (npc.vreg != nullptr)
    isa_extensions |= NEMU_ISA_EXT_V128_PREVIEW;
#ifdef RAPT_DUT_ZAWRS
  isa_extensions |= NEMU_ISA_EXT_ZAWRS;
#endif
#ifdef RAPT_DUT_ZFA
  isa_extensions |= NEMU_ISA_EXT_ZFA;
#endif
#ifdef RAPT_DUT_SSNPM
  isa_extensions |= NEMU_ISA_EXT_SSNPM;
#endif
#ifdef RAPT_DUT_SMNPM
  isa_extensions |= NEMU_ISA_EXT_SMNPM;
#endif
#ifdef RAPT_DUT_SVNAPOT
  isa_extensions |= NEMU_ISA_EXT_SVNAPOT;
#endif
#ifdef RAPT_DUT_SSCOFPMF
  isa_extensions |= NEMU_ISA_EXT_SSCOFPMF;
#endif
#ifdef RAPT_DUT_SMSTATEEN
  isa_extensions |= NEMU_ISA_EXT_SMSTATEEN_PREVIEW;
#endif
#ifdef RAPT_DUT_H_EXTENSION
  isa_extensions |= NEMU_ISA_EXT_H_GSTAGE_PREVIEW;
#endif
#ifdef RAPT_DUT_ZVBB
  isa_extensions |= NEMU_ISA_EXT_ZVBB;
#endif
#ifdef RAPT_DUT_ZVFHMIN
  isa_extensions |= NEMU_ISA_EXT_ZVFHMIN;
#endif
#ifdef RAPT_DUT_ZICCLSM_VECTOR
  isa_extensions |= NEMU_ISA_EXT_ZICCLSM_VECTOR;
#endif

  void *handle;
  handle = dlopen(ref_so_file, RTLD_LAZY);
  assert(handle);

  NemuISAQuery isa_query = (NemuISAQuery)dlsym(handle, "nemu_difftest_isa_query");
  if (isa_query == nullptr && isa_extensions)
  {
    fprintf(stderr, "[difftest] reference lacks optional ISA negotiation\n");
    abort();
  }
  if (isa_query != nullptr)
  {
    const NemuISAAPI *isa_api = isa_query(NEMU_ISA_API_VERSION, sizeof(NemuISAAPI));
    if (isa_api == nullptr || isa_api->version != NEMU_ISA_API_VERSION ||
        isa_api->size != sizeof(NemuISAAPI) || isa_api->xlen != sizeof(word_t) * 8 ||
        isa_api->configure == nullptr || isa_api->locked)
    {
      fprintf(stderr, "[difftest] NEMU reference ISA ABI or XLEN mismatch\n");
      abort();
    }
    if ((isa_extensions & ~isa_api->supported) ||
        isa_api->configure(isa_extensions) != 0)
    {
      fprintf(stderr, "[difftest] reference cannot enable ISA mask 0x%" PRIx64 "\n",
              isa_extensions);
      abort();
    }
    isa_api = isa_query(NEMU_ISA_API_VERSION, sizeof(NemuISAAPI));
    if (isa_api == nullptr || isa_api->enabled != isa_extensions)
    {
      fprintf(stderr, "[difftest] reference ISA mask did not take effect\n");
      abort();
    }
    printf("[difftest] reference ISA mask: 0x%" PRIx64 "\n", isa_extensions);
  }

  ref_difftest_memcpy = (void (*)(paddr_t, void *, size_t, bool))dlsym(handle, "difftest_memcpy");
  assert(ref_difftest_memcpy);
#ifdef RAPT_LARGE_PMEM
  ref_difftest_reset_pmem = (void (*)(void))dlsym(handle, "difftest_reset_pmem");
  assert(ref_difftest_reset_pmem && "2 GiB simulation needs a matching NEMU reference");
#endif

  ref_difftest_regcpy = (void (*)(void *dut, bool direction))dlsym(handle, "difftest_regcpy");
  assert(ref_difftest_regcpy);

  ref_difftest_exec = (void (*)(uint64_t))dlsym(handle, "difftest_exec");
  assert(ref_difftest_exec);

  ref_difftest_raise_intr = (void (*)(uint64_t))dlsym(handle, "difftest_raise_intr");
  assert(ref_difftest_raise_intr);
  ref_difftest_store_error = (void (*)(uint64_t, uint8_t))dlsym(handle, "difftest_store_error");
  ref_difftest_restore_store_error = (void (*)(uint64_t, uint64_t))dlsym(handle, "difftest_restore_store_error");
  store_error_queued = false;

  ref_difftest_state_version =
      (uint32_t (*)(void))dlsym(handle, "difftest_state_version");
  if (ref_difftest_state_version != NULL)
  {
    assert(ref_difftest_state_version() == DIFFTEST_STATE_VERSION);
  }

  // Optional: present in newer NEMU builds; absent in older refs (skip if missing).
  ref_difftest_set_meip = (void (*)(uint8_t))dlsym(handle, "difftest_set_meip");
  ref_difftest_set_msip = (void (*)(uint8_t))dlsym(handle, "difftest_set_msip");
  ref_difftest_set_mtip = (void (*)(uint8_t))dlsym(handle, "difftest_set_mtip");
  ref_difftest_set_stip = (void (*)(uint8_t))dlsym(handle, "difftest_set_stip");
  ref_difftest_set_seip = (void (*)(uint8_t))dlsym(handle, "difftest_set_seip");
  ref_difftest_plic_raise = (void (*)(uint32_t))dlsym(handle, "difftest_plic_raise");
  ref_difftest_checkpoint_sync =
      (void (*)(void *, uint32_t, uint32_t))dlsym(handle, "difftest_checkpoint_sync");
  ref_difftest_clear_reservation =
      (void (*)(void))dlsym(handle, "difftest_clear_reservation");
  ref_difftest_restore_sstc =
      (void (*)(uint64_t, uint64_t))dlsym(handle, "difftest_restore_sstc");

  void (*ref_difftest_init)(int) = (void (*)(int))dlsym(handle, "difftest_init");
  assert(ref_difftest_init);

  ref_difftest_init(port);
  if (npc.vreg != nullptr)
  {
    NemuDiffVectorQuery query =
        (NemuDiffVectorQuery)dlsym(handle, "nemu_difftest_vector_query");
    NemuDiffVectorCSRQuery csr_query =
        (NemuDiffVectorCSRQuery)dlsym(handle, "nemu_difftest_vector_csr_query");
    vector_reference = query == nullptr ? nullptr :
        query(NEMU_DIFF_VECTOR_VERSION, sizeof(NemuDiffVectorAPI));
    vector_csr_reference = csr_query == nullptr ? nullptr :
        csr_query(NEMU_DIFF_VECTOR_CSR_VERSION, sizeof(NemuDiffVectorCSRAPI));
    if (npc.vector_vlenb != NEMU_DIFF_VECTOR_VLENB || vector_reference == nullptr ||
        vector_csr_reference == nullptr ||
        vector_reference->xlen != sizeof(word_t) * 8 ||
        vector_csr_reference->xlen != sizeof(word_t) * 8 ||
        vector_reference->get_state == nullptr || vector_reference->set_state == nullptr ||
        vector_csr_reference->get_state == nullptr || vector_csr_reference->set_state == nullptr)
    {
      fprintf(stderr, "[difftest] V requires matching VLEN=128 register and CSR reference APIs\n");
      abort();
    }
    printf("[difftest] V enabled: compare all 32 vector registers and seven vector CSRs\n");
  }
  if (npc.hypervisor_csrs != nullptr)
  {
    NemuDiffHypervisorQuery hyp_query =
        (NemuDiffHypervisorQuery)dlsym(handle, "nemu_difftest_hypervisor_query");
    hypervisor_reference = hyp_query == nullptr ? nullptr :
        hyp_query(NEMU_DIFF_HYPERVISOR_VERSION, sizeof(NemuDiffHypervisorAPI));
    if (hypervisor_reference != nullptr &&
        (hypervisor_reference->xlen != sizeof(word_t) * 8 ||
         hypervisor_reference->get_state == nullptr ||
         hypervisor_reference->set_state == nullptr))
    {
      fprintf(stderr, "[difftest] invalid hypervisor CSR reference API\n");
      abort();
    }
  }
  ref_difftest_memcpy(MBASE, guest_to_host(MBASE), img_size, DIFFTEST_TO_REF);
  ref_difftest_memcpy(MROM_BASE, guest_to_host(MROM_BASE), MROM_SIZE, DIFFTEST_TO_REF);
  ref_difftest_memcpy(FLASH_BASE, guest_to_host(FLASH_BASE), FLASH_SIZE, DIFFTEST_TO_REF);
  ref_difftest_regcpy(&npc, DIFFTEST_TO_REF);
  sync_vector_reference();
  sync_hypervisor_reference();
#endif
}

#define CHECK_NPC_CSR_M(name)                                                                                           \
  if (*(ref->m##name) != *(npc.m##name))                                                                                \
  {                                                                                                                     \
    printf(FMT_RED("[ERROR]") " m" #name " is different! ref = " FMT_WORD_NO_PREFIX ", dut = " FMT_WORD_NO_PREFIX "\n", \
           *(ref->m##name), *(npc.m##name));                                                                            \
    is_same = false;                                                                                                    \
  }

#define CHECK_NPC_CSR_S(name)                                                                                           \
  if (*(ref->s##name) != *(npc.s##name))                                                                                \
  {                                                                                                                     \
    printf(FMT_RED("[ERROR]") " s" #name " is different! ref = " FMT_WORD_NO_PREFIX ", dut = " FMT_WORD_NO_PREFIX "\n", \
           *(ref->s##name), *(npc.s##name));                                                                            \
    is_same = false;                                                                                                    \
  }

static void checkregs(NPCState *ref, vaddr_t pc)
{
  bool is_same = true;
  if ((vaddr_t)(*(ref->rpc)) != pc)
  {
    printf(FMT_RED("[ERROR]") " pc is different! ref = " FMT_GREEN(FMT_WORD_NO_PREFIX) ", dut = " FMT_RED(FMT_WORD_NO_PREFIX) "\n",
           (vaddr_t)(*(ref->rpc)), pc);
    is_same = false;
  }
  if ((word_t)(*(ref->priv)) != (word_t)(*(npc.priv)))
  {
    printf(FMT_RED("[ERROR]") " priv is different! ref = " FMT_WORD_NO_PREFIX ", dut = " FMT_WORD_NO_PREFIX "\n",
           (word_t)(*(ref->priv)), (word_t)(*(npc.priv)));
    is_same = false;
  }
  // NEMU forces `inst = 0x00000013` (canonical NOP) for any instruction that
  // traps (load/store page fault, access fault, etc.) — see the nemu_longjmp
  // handlers in isa_exec_once() at nemu/src/isa/riscv/inst.c. The DUT instead
  // reports the actual faulting instruction word. On a correctly-handled trap
  // every architectural field (pc, priv, GPRs, scause/sepc/stval/satp, ...)
  // already matches; only this `inst` field differs by convention (e.g. a
  // legitimate copy_from_user load page fault on an unmapped user page). Skip
  // the inst-only comparison when the reference is the trap NOP sentinel to
  // avoid a false-positive divergence. This is safe: a real NOP in memory
  // yields ref==dut==0x13 (no mismatch), and a genuine trap/no-trap or
  // wrong-cause divergence is still caught by the pc/priv/CSR checks.
  if ((uint32_t)(*(ref->inst)) != *npc.inst && (uint32_t)(*(ref->inst)) != 0x00000013u)
  {
    printf(FMT_RED("[ERROR]") "    inst is different! ref = " FMT_WORD_NO_PREFIX ", dut = " FMT_WORD_NO_PREFIX "\n",
           (word_t)(*(ref->inst)), (word_t)(*npc.inst));
    is_same = false;
  }
  for (int i = 0; i < GPR_SIZE; i++)
  {
    if (ref->gpr[i] != npc.gpr[i])
    {
      printf(FMT_RED("[ERROR]") " reg[%s] is different! ref = " FMT_WORD_NO_PREFIX ", dut = " FMT_WORD_NO_PREFIX "\n",
             regs[i], ref->gpr[i], npc.gpr[i]);
      is_same = false;
    }
  }
  if (ref->fpr != nullptr && npc.fpr != nullptr)
  {
    for (int i = 0; i < FPR_SIZE; i++)
    {
      if (ref->fpr[i] != npc.fpr[i])
      {
        printf(FMT_RED("[ERROR] fpr[%d] is different! ref = %016" PRIx64 ", dut = %016" PRIx64 "\n"),
               i, ref->fpr[i], npc.fpr[i]);
        is_same = false;
      }
    }
  }
  if (ref->fcsr != nullptr && npc.fcsr != nullptr && *ref->fcsr != *npc.fcsr)
  {
    printf(FMT_RED("[ERROR] fcsr is different! ref = %08" PRIx32 ", dut = %08" PRIx32 "\n"),
           *ref->fcsr, *npc.fcsr);
    is_same = false;
  }
  CHECK_NPC_CSR_S(status);
  CHECK_NPC_CSR_S(ie____);
  CHECK_NPC_CSR_S(tvec__);

  CHECK_NPC_CSR_S(scratch);
  CHECK_NPC_CSR_S(epc___);
  CHECK_NPC_CSR_S(cause_);
  CHECK_NPC_CSR_S(tval__);
  CHECK_NPC_CSR_S(ip____);
  CHECK_NPC_CSR_S(atp___);

  CHECK_NPC_CSR_M(status);
  CHECK_NPC_CSR_M(edeleg);
  CHECK_NPC_CSR_M(ideleg);
  CHECK_NPC_CSR_M(ie____);
  CHECK_NPC_CSR_M(tvec__);

  CHECK_NPC_CSR_M(scratch);
  CHECK_NPC_CSR_M(epc___);
  CHECK_NPC_CSR_M(cause_);
  CHECK_NPC_CSR_M(tval__);
  CHECK_NPC_CSR_M(ip____);

  if (npc.vreg != nullptr)
  {
    NemuDiffVectorState registers;
    NemuDiffVectorCSRs csrs;
    Assert(vector_reference->get_state(0, &registers) == 0,
           "Cannot read reference vector registers");
    Assert(vector_csr_reference->get_state(0, &csrs) == 0,
           "Cannot read reference vector CSRs");
    if (memcmp(registers.reg, npc.vreg, sizeof(registers.reg)) != 0)
    {
      is_same = false;
      for (unsigned reg = 0; reg < 32; reg++)
        for (unsigned byte = 0; byte < npc.vector_vlenb; byte++)
        {
          const uint8_t dut_byte = npc.vreg[reg * npc.vector_vlenb + byte];
          if (registers.reg[reg][byte] != dut_byte)
            printf(FMT_RED("[ERROR] v%u byte %u differs: ref=%02x dut=%02x\n"), reg, byte,
                   registers.reg[reg][byte], dut_byte);
        }
    }
    static const char *names[] = {"vstart", "vxsat", "vxrm", "vcsr", "vl", "vtype", "vlenb"};
    for (unsigned index = 0; index < NEMU_DIFF_VECTOR_CSR_COUNT; index++)
      if (csrs.value[index] != npc.vector_csrs[index])
      {
        printf(FMT_RED("[ERROR] %s differs: ref=%016" PRIx64 " dut=" FMT_WORD_NO_PREFIX "\n"),
               names[index], csrs.value[index], npc.vector_csrs[index]);
        is_same = false;
      }
  }

  if (npc.hypervisor_csrs != nullptr && hypervisor_reference != nullptr)
  {
    NemuDiffHypervisorState hstate = {};
    Assert(hypervisor_reference->get_state(0, &hstate) == 0,
           "Cannot read reference hypervisor CSRs");
    const uint8_t dut_virt = npc.virt != nullptr ? (*npc.virt & 1u) : 0u;
    if (hstate.virt != dut_virt)
    {
      printf(FMT_RED("[ERROR] virt differs: ref=%u dut=%u\n"), hstate.virt, dut_virt);
      is_same = false;
    }
    static const char *hnames[NEMU_DIFF_HYPERVISOR_CSR_COUNT] = {
      "menvcfg", "senvcfg", "mstateen0", "mstateen1", "mstateen2", "mstateen3",
      "hstatus", "hedeleg", "hideleg", "hie", "htimedelta", "hcounteren",
      "henvcfg", "hstateen0", "hstateen1", "hstateen2", "hstateen3", "htval",
      "hip", "hvip", "htinst", "hgatp", "vsstatus", "vsie", "vstvec",
      "vsscratch", "vsepc", "vscause", "vstval", "vsip", "vstimecmp", "vsatp",
      "mtinst", "mtval2"
    };
    for (unsigned index = 0; index < NEMU_DIFF_HYPERVISOR_CSR_COUNT; index++)
      if (hstate.csr[index] != npc.hypervisor_csrs[index])
      {
        printf(FMT_RED("[ERROR] %s differs: ref=%016" PRIx64 " dut=%016" PRIx64 "\n"),
               hnames[index], hstate.csr[index], npc.hypervisor_csrs[index]);
        is_same = false;
      }
  }

  if (!is_same)
  {
    // Enhanced error reporting: show load/store context if available
    uint32_t inst = *npc.inst;
    uint32_t opcode = inst & 0x7f;

    // Instruction memory dump: when inst differs, compare DUT vs NEMU memory
    // at the failing PC's physical address. Distinguishes L1I staleness from
    // memory-side divergence. Linux kernel mapping for this build: virtual
    // 0xc0000000 -> physical 0x80400000 (PAGE_OFFSET=0xc0000000, kernel
    // physical base 0x80400000 because OpenSBI reserves the first 4MB).
    if ((uint32_t)(*(ref->inst)) != *npc.inst)
    {
      paddr_t pc_paddr = (paddr_t)pc;
      if ((pc & 0xc0000000u) == 0xc0000000u)
      {
        pc_paddr = (paddr_t)(pc - 0x3FC00000u);
      }
      if (pc_paddr >= MBASE && (uint64_t)pc_paddr + 16 <= (uint64_t)MBASE + MSIZE)
      {
        uint8_t ref_mem[16] = {};
        uint8_t *npc_mem = (uint8_t *)guest_to_host(pc_paddr & ~(paddr_t)0xf);
        ref_difftest_memcpy(pc_paddr & ~(paddr_t)0xf, ref_mem, 16, DIFFTEST_TO_DUT);
        printf(FMT_RED("[INST MEM DUMP]") " vpc=" FMT_WORD_NO_PREFIX " ppc=" FMT_WORD_NO_PREFIX
                                          " (aligned to 16)\n",
               (word_t)pc, (word_t)(pc_paddr & ~(paddr_t)0xf));
        printf("  npc_mem (DUT): ");
        for (int j = 0; j < 16; j++)
          printf("%02x ", npc_mem[j]);
        printf("\n");
        printf("  ref_mem (REF): ");
        for (int j = 0; j < 16; j++)
          printf("%02x ", ref_mem[j]);
        printf("\n");
        printf("  -> If npc_mem matches ref_mem: L1I cache staleness (fence.i bug).\n");
        printf("  -> If they differ: memory-side store divergence.\n");
      }
    }

    // Check if the instruction is a load (opcode 0000011 = 0x03)
    if (opcode == 0x03)
    {
      // Reconstruct virtual load address from register file: rs1 + imm
      uint32_t rs1_idx = (inst >> 15) & 0x1f;
      int32_t imm = (int32_t)inst >> 20;
      word_t npc_ld_vaddr = npc.gpr[rs1_idx] + (word_t)imm;

      printf(FMT_RED("[LOAD INFO]") " npc: vaddr=" FMT_WORD_NO_PREFIX " (rs1[%s]=" FMT_WORD_NO_PREFIX " + imm=%d)\n",
             npc_ld_vaddr, regs[rs1_idx], npc.gpr[rs1_idx], imm);
      printf(FMT_RED("[LOAD INFO]") " ref: vaddr=" FMT_WORD_NO_PREFIX ", paddr=" FMT_WORD_NO_PREFIX
                                    ", rdata=" FMT_WORD_NO_PREFIX ", rlen=%d\n",
             (word_t)ref->rvaddr, (word_t)ref->rpaddr, (word_t)ref->rdata, (int)ref->rlen);

      // Compare physical memory content at ref's physical address
      paddr_t ref_paddr = ref->rpaddr;
      if (ref_paddr >= MBASE && (uint64_t)ref_paddr < (uint64_t)MBASE + MSIZE)
      {
        uint8_t ref_mem[16] = {};
        uint8_t *npc_mem = (uint8_t *)guest_to_host(ref_paddr & ~(paddr_t)0xf);
        ref_difftest_memcpy(ref_paddr & ~(paddr_t)0xf, ref_mem, 16, DIFFTEST_TO_DUT);
        printf(FMT_RED("[MEM DUMP]") " paddr=" FMT_WORD_NO_PREFIX " (aligned to 16)\n",
               (word_t)(ref_paddr & ~(paddr_t)0xf));
        printf("  npc_mem: ");
        for (int j = 0; j < 16; j++)
          printf("%02x ", npc_mem[j]);
        printf("\n");
        printf("  ref_mem: ");
        for (int j = 0; j < 16; j++)
          printf("%02x ", ref_mem[j]);
        printf("\n");
      }
    }

    // Check if the instruction is a store (opcode 0100011 = 0x23)
    if (opcode == 0x23)
    {
      printf(FMT_RED("[STORE INFO]") " ref: vwaddr=" FMT_WORD_NO_PREFIX ", pwaddr=" FMT_WORD_NO_PREFIX
                                     ", wdata=" FMT_WORD_NO_PREFIX ", len=%d\n",
             (word_t)ref->vwaddr, (word_t)ref->pwaddr, (word_t)ref->wdata, (int)ref->len);
    }

    printf(FMT_RED("[ERROR]") " npc.pc: " FMT_WORD_NO_PREFIX "\n", pc);
    npc.state = NPC_ABORT;
  }
}

static bool sync_pre_exec_ip_read(uint32_t retire_count, bool commit_trap)
{
  if (commit_trap || retire_count != 1 || npc.mip____ == nullptr) return false;
  const uint32_t inst = *npc.inst;
  const uint32_t funct3 = (inst >> 12) & 0x7u;
  const uint32_t rd = (inst >> 7) & 0x1fu;
  if ((inst & 0x7fu) != 0x73u || funct3 == 0u || funct3 == 4u || rd == 0u)
    return false;
  const uint16_t csr = (inst >> 20) & 0xfffu;
  if (csr != 0x344u && csr != 0x144u && csr != 0x644u && csr != 0x244u)
    return false;
  const word_t rd_val = npc.gpr[rd];
  const word_t post_mip = *npc.mip____;
  const uint8_t dut_virt = npc.virt != nullptr ? (*npc.virt & 1u) : 0u;
#ifdef CONFIG_ISA64
  const bool stce = npc.menvcfg != nullptr && (((uint64_t)*npc.menvcfg >> 63) & 1u);
#else
  const bool stce = npc.menvcfgh != nullptr && ((*npc.menvcfgh >> 31) & 1u);
#endif
  const bool has_hyp = npc.hypervisor_csrs != nullptr && hypervisor_reference != nullptr;
  const uint64_t hideleg = has_hyp ? npc.hypervisor_csrs[NEMU_DIFF_HCSR_HIDELEG] : 0ull;
  const uint64_t henvcfg = has_hyp ? npc.hypervisor_csrs[NEMU_DIFF_HCSR_HENVCFG] : 0ull;
  const bool vstce = stce && ((henvcfg >> 63) & 1u);
  bool resync = false;

  if (csr == 0x344u && !dut_virt && ref_difftest_set_mtip != nullptr)
  {
    const uint8_t pre_mtip = (rd_val >> 7) & 1u;
    if (pre_mtip != ((post_mip >> 7) & 1u))
    {
      ref_difftest_set_mtip(pre_mtip);
      resync = true;
    }
  }
  const bool stip_delegated = npc.mideleg != nullptr && ((*npc.mideleg >> 5) & 1u) != 0;
  if (stce && ref_difftest_set_stip != nullptr && !dut_virt &&
      (csr == 0x344u || (csr == 0x144u && stip_delegated)))
  {
    const uint8_t pre_stip = (rd_val >> 5) & 1u;
    if (pre_stip != ((post_mip >> 5) & 1u))
    {
      ref_difftest_set_stip(pre_stip);
      resync = true;
    }
  }
  if (vstce && has_hyp && hypervisor_reference->set_mtime != nullptr &&
      npc.clint_mtime != nullptr)
  {
    int vstip_bit = -1;
    if (!dut_virt && (csr == 0x344u || csr == 0x644u)) vstip_bit = 6;
    else if ((csr == 0x244u && !dut_virt && ((hideleg >> 6) & 1u)) ||
             (csr == 0x144u && dut_virt && ((hideleg >> 6) & 1u)))
      vstip_bit = 5;
    if (vstip_bit >= 0)
    {
      const uint8_t pre_vstip = (rd_val >> vstip_bit) & 1u;
      if (pre_vstip != ((post_mip >> 6) & 1u))
      {
        const uint64_t delta = npc.hypervisor_csrs[NEMU_DIFF_HCSR_HTIMEDELTA];
        const uint64_t cmp = npc.hypervisor_csrs[NEMU_DIFF_HCSR_VSTIMECMP];
        const uint64_t target_vtime = pre_vstip ? cmp : (cmp - 1ull);
        hypervisor_reference->set_mtime(target_vtime - delta);
        resync = true;
      }
    }
  }
  return resync;
}

static void restore_post_exec_ip()
{
  if (npc.mip____ != nullptr)
  {
    const word_t post_mip = *npc.mip____;
    if (ref_difftest_set_mtip != nullptr)
      ref_difftest_set_mtip((post_mip >> 7) & 1u);
#ifdef CONFIG_ISA64
    const bool stce = npc.menvcfg != nullptr && (((uint64_t)*npc.menvcfg >> 63) & 1u);
#else
    const bool stce = npc.menvcfgh != nullptr && ((*npc.menvcfgh >> 31) & 1u);
#endif
    if (stce && ref_difftest_set_stip != nullptr)
      ref_difftest_set_stip((post_mip >> 5) & 1u);
  }
  if (hypervisor_reference != nullptr && hypervisor_reference->set_mtime != nullptr &&
      npc.clint_mtime != nullptr)
  {
    hypervisor_reference->set_mtime(*npc.clint_mtime);
  }
}

void difftest_step(vaddr_t pc, uint32_t retire_count, bool commit_trap)
{
  if (!difftest_enabled)
    return;
  NPCState ref_r;

  // TEST-ONLY: deterministic fault injection to validate the LightSSS
  // snapshot-on-divergence path without perturbing the RTL/reference model.
  // When NSIM_FAULT_DIFFTEST_AT=<N> is set, force a clean difftest divergence
  // (NPC_ABORT) at the group boundary reaching N committed instructions.
  // For snapshot tests, N must be large enough that at
  // least one LightSSS progress-fork has already happened (see
  // NSIM_PROGRESS_CYCLES). Never active unless the env var is present.
  static long fault_at = []() -> long
  {
    const char *e = getenv("NSIM_FAULT_DIFFTEST_AT");
    return e ? strtol(e, NULL, 0) : 0;
  }();
  static long commit_seen = 0;
  if (fault_at > 0)
  {
    long previous_seen = commit_seen;
    commit_seen += retire_count;
    if (previous_seen < fault_at && commit_seen >= fault_at)
    {
      // Architectural snapshots are available only at group boundaries.
      printf(FMT_RED("[ERROR]") " injected difftest fault at retirement group ending %ld (requested %ld), pc=" FMT_WORD_NO_PREFIX "\n",
             commit_seen, fault_at, pc);
      npc.state = NPC_ABORT;
      return;
    }
  }

  if (skip_dut_nr_inst > 0)
  {
    skip_dut_nr_inst--;
    should_diff_mem = false;
    return;
  }

  if (is_skip_ref)
  {
    ref_difftest_regcpy(&npc, DIFFTEST_TO_REF);
    sync_vector_reference();
    sync_hypervisor_reference();
    is_skip_ref = false;
    should_diff_mem = false;
    return;
  }

  /* LR/SC permits a conforming implementation to fail SC spuriously.  When
   * the DUT reports such a failure, invalidate the reference reservation
   * before executing the same SC.  NEMU then also returns failure and does
   * not perform a memory write that the DUT did not make. */
  const uint32_t dut_inst = *npc.inst;
  const bool dut_is_sc = (dut_inst & 0x7f) == 0x2f
      && ((dut_inst >> 27) & 0x1f) == 0x03;
  const uint32_t dut_rd = (dut_inst >> 7) & 0x1f;
  if (dut_is_sc && npc.gpr[dut_rd] != 0)
  {
    if (ref_difftest_clear_reservation != NULL)
      ref_difftest_clear_reservation();
    else
    {
      /* Compatibility with an older reference shared object. */
      ref_difftest_regcpy(&npc, DIFFTEST_TO_REF);
      sync_vector_reference();
      sync_hypervisor_reference();
      should_diff_mem = false;
      return;
    }
  }

  // Group stepping belongs after reset/checkpoint/MMIO skip handling. No
  // intermediate retirement may execute REF before its state is synchronized.
  const bool ip_resync = sync_pre_exec_ip_read(retire_count, commit_trap);
  ref_difftest_exec(retire_count);
  if (ip_resync)
    restore_post_exec_ip();
  // DUT flops already include this edge's external write response. Apply it
  // after retired CSR semantics (hardware wins W1C), before comparing MIP.
  // The cycle-level call remains necessary for no-commit/skip paths.
  difftest_apply_store_error();
  ref_difftest_regcpy(&ref_r, DIFFTEST_TO_DUT);

  if (ref_r.skip)
  {
    ref_difftest_regcpy(&npc, DIFFTEST_TO_REF);
    sync_vector_reference();
    sync_hypervisor_reference();
    should_diff_mem = false;
  }
  else
  {
    // Store address/data difftest: compare on non-skipped store commits
    if (should_diff_mem)
    {
      int len = ref_r.len;
      word_t npc_wdata = npc.wdata;
      word_t ref_wdata = ref_r.wdata;
      switch (len)
      {
      case 1:
        npc_wdata = (uint8_t)(npc_wdata);
        ref_wdata = (uint8_t)(ref_wdata);
        break;
      case 2:
        npc_wdata = (uint16_t)(npc_wdata);
        ref_wdata = (uint16_t)(ref_wdata);
        break;
      case 4:
        npc_wdata = (uint32_t)(npc_wdata);
        ref_wdata = (uint32_t)(ref_wdata);
        break;
      default:
        npc_wdata = (uint64_t)(npc_wdata);
        ref_wdata = (uint64_t)(ref_wdata);
        break;
      }
      if ((npc.pwaddr != ref_r.pwaddr) || (npc_wdata != ref_wdata))
      {
        printf(FMT_RED("[STORE DIFF]") " npc: paddr=" FMT_WORD_NO_PREFIX ", wdata=" FMT_WORD_NO_PREFIX
                                       ", raw=" FMT_WORD_NO_PREFIX ", wstrb=" FMT_WORD_NO_PREFIX ", pc=" FMT_WORD_NO_PREFIX "\n",
               (word_t)npc.pwaddr, npc_wdata, (word_t)npc.wdata,
               (word_t)npc.wstrb, pc);
        printf(FMT_RED("[STORE DIFF]") " ref: paddr=" FMT_WORD_NO_PREFIX ", wdata=" FMT_WORD_NO_PREFIX
                                       ", len=%d, pc=" FMT_WORD_NO_PREFIX "\n",
               (word_t)(ref_r.pwaddr), ref_wdata, (int)(ref_r.len), (word_t)(*ref_r.rpc));
        reg_display(32);
        npc.state = NPC_ABORT;
      }
      should_diff_mem = false;
    }
    checkregs(&ref_r, *npc.rpc);
  }
}

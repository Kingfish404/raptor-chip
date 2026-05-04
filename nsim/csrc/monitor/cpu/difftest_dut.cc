#include <common.h>
#include <cpu.h>
#include <memory.h>
#include <dlfcn.h>

extern NPCState npc;
extern char *regs[];

uint8_t pmem_ref[MSIZE] = {};

void (*ref_difftest_memcpy)(paddr_t addr, void *buf, size_t n, bool direction) = NULL;
void (*ref_difftest_regcpy)(void *dut, bool direction) = NULL;
void (*ref_difftest_exec)(uint64_t n) = NULL;
void (*ref_difftest_raise_intr)(uint64_t NO) = NULL;
void (*ref_difftest_set_meip)(uint8_t val) = NULL;
void (*ref_difftest_plic_raise)(uint32_t src) = NULL;

static bool is_skip_ref = false;
static bool should_diff_mem = false;
static int skip_dut_nr_inst = 0;
// When `-d <ref.so>` is not supplied, the simulator runs without comparing
// against a reference. This is useful for coverage / pk-based workloads that
// exercise paths the current REF doesn't model identically (e.g. Sv32 paging,
// medeleg-driven exception delegation). Set in init_difftest().
static bool difftest_enabled = false;

bool difftest_is_enabled() { return difftest_enabled; }

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
  if (!difftest_enabled) return;
  skip_dut_nr_inst += nr_dut;

  while (nr_ref-- > 0)
  {
    ref_difftest_exec(1);
  }
}

void difftest_raise_intr(uint64_t NO)
{
  if (!difftest_enabled) return;
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

void init_difftest(char *ref_so_file, long img_size, int port)
{
#ifdef CONFIG_DIFFTEST
  if (ref_so_file == NULL) {
    printf("[difftest] DISABLED: no `-d <ref.so>` argument supplied; "
           "register/CSR comparison against REF is skipped.\n");
    difftest_enabled = false;
    return;
  }
  difftest_enabled = true;

  void *handle;
  handle = dlopen(ref_so_file, RTLD_LAZY);
  assert(handle);

  ref_difftest_memcpy = (void (*)(paddr_t, void *, size_t, bool))dlsym(handle, "difftest_memcpy");
  assert(ref_difftest_memcpy);

  ref_difftest_regcpy = (void (*)(void *dut, bool direction))dlsym(handle, "difftest_regcpy");
  assert(ref_difftest_regcpy);

  ref_difftest_exec = (void (*)(uint64_t))dlsym(handle, "difftest_exec");
  assert(ref_difftest_exec);

  ref_difftest_raise_intr = (void (*)(uint64_t))dlsym(handle, "difftest_raise_intr");
  assert(ref_difftest_raise_intr);

  // Optional: present in newer NEMU builds; absent in older refs (skip if missing).
  ref_difftest_set_meip = (void (*)(uint8_t))dlsym(handle, "difftest_set_meip");
  ref_difftest_plic_raise = (void (*)(uint32_t))dlsym(handle, "difftest_plic_raise");

  void (*ref_difftest_init)(int) = (void (*)(int))dlsym(handle, "difftest_init");
  assert(ref_difftest_init);

  ref_difftest_init(port);
  ref_difftest_memcpy(MBASE, guest_to_host(MBASE), img_size, DIFFTEST_TO_REF);
  ref_difftest_memcpy(MROM_BASE, guest_to_host(MROM_BASE), MROM_SIZE, DIFFTEST_TO_REF);
  ref_difftest_memcpy(FLASH_BASE, guest_to_host(FLASH_BASE), FLASH_SIZE, DIFFTEST_TO_REF);
  ref_difftest_regcpy(&npc, DIFFTEST_TO_REF);
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
  if ((uint32_t)(*(ref->inst)) != *npc.inst)
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
      if (pc_paddr >= MBASE && pc_paddr + 16 <= MBASE + MSIZE)
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
      if (ref_paddr >= MBASE && ref_paddr < MBASE + MSIZE)
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

void difftest_step(vaddr_t pc)
{
  if (!difftest_enabled) return;
  NPCState ref_r;

  if (skip_dut_nr_inst > 0)
  {
    skip_dut_nr_inst--;
    should_diff_mem = false;
    return;
  }

  if (is_skip_ref)
  {
    ref_difftest_regcpy(&npc, DIFFTEST_TO_REF);
    is_skip_ref = false;
    should_diff_mem = false;
    return;
  }

  ref_difftest_exec(1);
  ref_difftest_regcpy(&ref_r, DIFFTEST_TO_DUT);

  if (ref_r.skip)
  {
    ref_difftest_regcpy(&npc, DIFFTEST_TO_REF);
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
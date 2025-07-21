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

static bool is_skip_ref = false;
static bool should_diff_mem = false;
static int skip_dut_nr_inst = 0;

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
  skip_dut_nr_inst += nr_dut;

  while (nr_ref-- > 0)
  {
    ref_difftest_exec(1);
  }
}

static void checkmem(uint8_t *ref, uint8_t *dut, size_t n)
{
  ref_difftest_memcpy(MBASE, ref, n, DIFFTEST_TO_DUT);
  for (size_t i = 0; i < n; i++)
  {
    if (ref[i] != dut[i])
    {
      printf(FMT_RED("[ERROR]") " mem[%zx] is different! ref = " FMT_WORD_NO_PREFIX ", dut = " FMT_WORD_NO_PREFIX "\n",
             i, ref[i], dut[i]);
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
  assert(ref_so_file != NULL);

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
  if ((vaddr_t)(*(ref->cpc)) != pc)
  {
    printf(FMT_RED("[ERROR]") " pc is different! ref = " FMT_GREEN(FMT_WORD_NO_PREFIX) ", dut = " FMT_RED(FMT_WORD_NO_PREFIX) "\n",
           (vaddr_t)(*(ref->cpc)), pc);
    is_same = false;
  }
  if ((uint32_t)(*(ref->inst)) != *npc.inst)
  {
    printf(FMT_RED("[ERROR]") "    inst is different! ref = " FMT_WORD_NO_PREFIX ", dut = " FMT_WORD_NO_PREFIX "\n",
           *(ref->inst), *npc.inst);
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
    checkmem(pmem_ref, guest_to_host(MBASE), MSIZE);
    printf(FMT_RED("[ERROR]") " npc.pc: " FMT_WORD_NO_PREFIX "\n", pc);
    npc.state = NPC_ABORT;
  }
}

void difftest_step(vaddr_t pc)
{
  NPCState ref_r;

  if (skip_dut_nr_inst > 0)
  {
    skip_dut_nr_inst--;
    return;
  }

  if (is_skip_ref)
  {
    // printf("Skip start at ref.cpc: " FMT_WORD_NO_PREFIX ", npc.cpc: " FMT_WORD_NO_PREFIX
    //        ", ref.pc: " FMT_WORD_NO_PREFIX ", npc.pc: " FMT_WORD_NO_PREFIX "\n",
    //        *ref_r.cpc, *npc.cpc, *ref_r.pc, *npc.pc);
    ref_difftest_regcpy(&npc, DIFFTEST_TO_REF);
    is_skip_ref = false;
    // printf("Skip end   at ref.cpc: " FMT_WORD_NO_PREFIX ", npc.cpc: " FMT_WORD_NO_PREFIX
    //        ", ref.pc: " FMT_WORD_NO_PREFIX ", npc.pc: " FMT_WORD_NO_PREFIX "\n",
    //        *ref_r.cpc, *npc.cpc, *ref_r.pc, *npc.pc);
    should_diff_mem = false;
    return;
  }

  ref_difftest_exec(1);

  if (0)
  {
    ref_difftest_regcpy(&ref_r, DIFFTEST_TO_DUT);
    int low2addr = npc.vwaddr & 0x3;
    int len = ref_r.len;
    word_t align_wdata = ((word_t)npc.wdata);
    word_t ref_wdata = ref_r.wdata;
    switch (len)
    {
    case 1:
      align_wdata = (uint8_t)(align_wdata);
      ref_wdata = (uint8_t)(ref_wdata);
      break;
    case 2:
      align_wdata = (uint16_t)(align_wdata);
      ref_wdata = (uint16_t)(ref_wdata);
      break;
    case 4:
      align_wdata = (uint32_t)(align_wdata);
      ref_wdata = (uint32_t)(ref_wdata);
      break;
    default:
      align_wdata = (uint64_t)(align_wdata);
      ref_wdata = (uint64_t)(ref_wdata);
      break;
    }
    if ((npc.vwaddr != ref_r.vwaddr) || (align_wdata != ref_wdata))
    {
      printf("[npc.vwaddr: " FMT_WORD_NO_PREFIX ", wdata: " FMT_WORD_NO_PREFIX "], "
             "rawdta: " FMT_WORD_NO_PREFIX ", wstrb: %x, pc: " FMT_WORD_NO_PREFIX "\n",
             (word_t)npc.vwaddr, align_wdata, (word_t)npc.wdata,
             npc.wstrb, *npc.cpc);
      printf("[ref.vwaddr: " FMT_WORD_NO_PREFIX ", wdata: " FMT_WORD_NO_PREFIX "], "
             "pwaddr: " FMT_WORD_NO_PREFIX ",   len: %x, pc: " FMT_WORD_NO_PREFIX "\n",
             (ref_r.vwaddr), ref_wdata, ref_r.pwaddr, ref_r.len, *ref_r.cpc);
      reg_display(32);
      npc.state = NPC_ABORT;
    }
    ref_r.vwaddr = 0;
    ref_r.pwaddr = 0;
#ifdef CONFIG_MEM_DIFFTEST
    checkmem(pmem_ref, guest_to_host(MBASE), MSIZE);
#endif
    should_diff_mem = false;
  }

  ref_difftest_regcpy(&ref_r, DIFFTEST_TO_DUT);
  if (ref_r.skip)
  {
    // printf("Skip instruction at ref.cpc: " FMT_WORD_NO_PREFIX ", npc.cpc: " FMT_WORD_NO_PREFIX
    //        ", ref.pc: " FMT_WORD_NO_PREFIX ", npc.pc: " FMT_WORD_NO_PREFIX "\n",
    //        *ref_r.cpc, *npc.cpc, *ref_r.pc, *npc.pc);
    ref_difftest_regcpy(&npc, DIFFTEST_TO_REF);
  }
  else
  {
    checkregs(&ref_r, *npc.cpc);
  }

  // printf("Diff test at ref.cpc: " FMT_WORD_NO_PREFIX ", npc.cpc: " FMT_WORD_NO_PREFIX "\n",
  //        *ref_r.cpc, *npc.cpc);
}
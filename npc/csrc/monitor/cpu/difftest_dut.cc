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
  printf("skip %d instructions in dut\n", nr_dut);

  while (nr_ref-- > 0)
  {
    ref_difftest_exec(1);
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

#define CHECK_NPC_CSR(name)                                                                                             \
  if (*(ref->m##name) != *(npc.m##name))                                                                                \
  {                                                                                                                     \
    printf(FMT_RED("[ERROR]") " m" #name " is different! ref = " FMT_WORD_NO_PREFIX ", dut = " FMT_WORD_NO_PREFIX "\n", \
           *(ref->m##name), *(npc.m##name));                                                                            \
    is_same = false;                                                                                                    \
  }

static void checkregs(NPCState *ref, vaddr_t pc)
{
  bool is_same = true;
  if ((vaddr_t)(*(ref->pc)) != pc)
  {
    printf(FMT_RED("[ERROR]") " pc is different! ref = " FMT_GREEN(FMT_WORD) ", dut = " FMT_RED(FMT_WORD) "\n",
           (vaddr_t)(*(ref->pc)), pc);
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
  CHECK_NPC_CSR(cause);
  CHECK_NPC_CSR(tvec);
  CHECK_NPC_CSR(epc);
  CHECK_NPC_CSR(status);

  if (!is_same)
  {
    npc.state = NPC_ABORT;
  }
}

#ifdef CONFIG_MEM_DIFFTEST
static void checkmem(uint8_t *ref, uint8_t *dut, size_t n)
{
  for (size_t i = 0; i < n; i++)
  {
    if (ref[i] != dut[i])
    {
      printf(FMT_RED("[ERROR]") " mem[%x] is different! ref = " FMT_WORD_NO_PREFIX ", dut = " FMT_WORD_NO_PREFIX "\n",
             (word_t)i, ref[i], dut[i]);
      // print the before 16 bits and after 16 bits of memory
      printf("mem_ref: ");
      for (int j = 0; j < 16; j++)
      {
        printf("%02x ", ref[i - 8 + j]);
      }
      printf("\n");
      printf("mem_dut: ");
      for (int j = 0; j < 16; j++)
      {
        printf("%02x ", dut[i - 8 + j]);
      }
      printf("\n");
      npc.state = NPC_ABORT;
      return;
    }
  }
}
#endif

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
    ref_difftest_regcpy(&npc, DIFFTEST_TO_REF);
    is_skip_ref = false;
    return;
  }

  ref_difftest_exec(1);
  ref_difftest_regcpy(&ref_r, DIFFTEST_TO_DUT);
  checkregs(&ref_r, pc);
  // vaddr_show(pc, 12);

#ifdef CONFIG_MEM_DIFFTEST
  if (should_diff_mem)
  {
    ref_difftest_memcpy(MBASE, pmem_ref, MSIZE, DIFFTEST_TO_DUT);
    checkmem(pmem_ref, guest_to_host(MBASE), MSIZE);
    should_diff_mem = false;
  }
#endif
}
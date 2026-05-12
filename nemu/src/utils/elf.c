#include <common.h>
#include <isa.h>
#include <cpu/cpu.h>
#include <isa-def.h>
#include <elf.h>

#define MAX_FTRACE_SIZE 1024
#define MAX_ELF_SIZE 32 * 1024

typedef enum
{
  INST_ECALL = 0x00000073,
  INST_MRET = 0x30200073,
  INST_SRET = 0x10200073,
  INST_RET_ = 0x00008067,
  INST_EBREAK = 0x00100073,
} rv_inst_t;

typedef enum
{
  OP_JAL_ = 0b1101111,
  OP_JALR = 0b1100111,
} rv_opcode_t;

typedef struct Ftrace
{
  word_t pc;
  word_t npc;
  word_t depth;
  word_t inst;
  /* Interrupt cause if this entry represents an intr entry, else
   * INTR_EMPTY. Stored on the hot path; the human-readable text is
   * built lazily by cpu_show_ftrace() to keep ftrace_add() Capstone-free. */
  word_t intr_cause;
  bool ret;
} Ftrace;

Ftrace ftracebuf[MAX_FTRACE_SIZE];
int ftracehead = 0;
int ftracedepth = 0;
int ftracedepth_max = 0;
char elfbuf[MAX_ELF_SIZE];

typedef MUXDEF(CONFIG_ISA64, Elf64_Ehdr, Elf32_Ehdr) Elf_Ehdr;
typedef MUXDEF(CONFIG_ISA64, Elf64_Shdr, Elf32_Shdr) Elf_Shdr;
typedef MUXDEF(CONFIG_ISA64, Elf64_Sym, Elf32_Sym) Elf_Sym;
Elf_Ehdr elf_ehdr;
Elf_Shdr *elfshdr_symtab = NULL, *elfshdr_strtab = NULL;

void isa_parser_elf(char *filename)
{
  FILE *fp = fopen(filename, "rb");
  Assert(fp, "Can not open '%s'", filename);
  fseek(fp, 0, SEEK_END);
  long size = ftell(fp);
  Assert(size < MAX_ELF_SIZE, "elf file is too large");

  fseek(fp, 0, SEEK_SET);
  int ret = fread(&elf_ehdr, sizeof(elf_ehdr), 1, fp);
  assert(ret == 1);
  assert(memcmp(elf_ehdr.e_ident, ELFMAG, SELFMAG) == 0);
  fseek(fp, 0, SEEK_SET);
  ret = fread(elfbuf, size, 1, fp);
  assert(ret == 1);
  fclose(fp);

  printf("e_ident: ");
  for (size_t i = 0; i < SELFMAG; i++)
  {
    printf("%02x ", elf_ehdr.e_ident[i]);
  }
  printf("\n");
  printf("e_type: %d\t", elf_ehdr.e_type);
  printf("e_machine: %d\t", elf_ehdr.e_machine);
  printf("e_version: %d\n", elf_ehdr.e_version);
  printf("e_entry: " FMT_WORD "\t", elf_ehdr.e_entry);
  printf("e_phoff: " FMT_WORD "\n", elf_ehdr.e_phoff);
  printf("e_shoff: " FMT_WORD "\t", elf_ehdr.e_shoff);
  printf("e_flags: 0x%016x\n", elf_ehdr.e_flags);
  printf("e_ehsize: %d\t", elf_ehdr.e_ehsize);
  printf("e_phentsize: %d\t", elf_ehdr.e_phentsize);
  printf("e_phnum: %d\n", elf_ehdr.e_phnum);
  printf("e_shentsize: %d\t", elf_ehdr.e_shentsize);
  printf("e_shnum: %d\t", elf_ehdr.e_shnum);
  printf("e_shstrndx: %d\n", elf_ehdr.e_shstrndx);

  for (size_t i = 0; i < elf_ehdr.e_shnum; i++)
  {
    Elf_Shdr *shdr = (Elf_Shdr *)(elfbuf + elf_ehdr.e_shoff + i * elf_ehdr.e_shentsize);
    if (shdr->sh_type == SHT_SYMTAB)
    {
      elfshdr_symtab = shdr;
    }
    else if (shdr->sh_type == SHT_STRTAB)
    {
      elfshdr_strtab = shdr;
    }
    if (elfshdr_symtab != NULL && elfshdr_strtab != NULL)
    {
      break;
      for (size_t j = 0; j < elfshdr_symtab->sh_size / sizeof(Elf_Sym); j++)
      {
        Elf_Sym *sym = (Elf_Sym *)(elfbuf + elfshdr_symtab->sh_offset + j * sizeof(Elf_Sym));
        printf("" FMT_WORD ": %s\n", sym->st_value, elfbuf + elfshdr_strtab->sh_offset + sym->st_name);
      }
      break;
    }
  }
}

static int during_intr_trap = 0;

void ftrace_add(word_t pc, word_t npc, word_t inst)
{
#if defined(CONFIG_ISA_riscv)
  uint32_t opcode = BITS(inst, 6, 0);
  int is_call = 0, is_ret = 0;
  word_t intr_cause = INTR_EMPTY;

  /* Fast classification. NOTE: no sprintf, no disassemble — those run
   * lazily in cpu_show_ftrace(). The only state we keep here is what
   * the call/ret depth tracking actually needs. */
  if (cpu.raise_intr != INTR_EMPTY)
  {
    intr_cause = cpu.raise_intr;
    is_call = 1;
    during_intr_trap = 1;
    cpu.raise_intr = INTR_EMPTY;
  }
  else
  {
    switch (inst)
    {
    case INST_ECALL:
      is_call = 1;
      break;
    case INST_EBREAK:
      is_call = 1;
      break;
    case INST_RET_:
      is_ret = 1;
      break;
    case INST_MRET:
    case INST_SRET:
      is_ret = during_intr_trap;
      during_intr_trap = 0;
      break;
    default:
      /* Hot path's overwhelmingly common exit: the per-instruction
       * branch into ftrace_add bottoms out here for non-call/ret ops. */
      switch (opcode)
      {
      case OP_JAL_:
        is_call = (inst & 0xfff) != 0x0000006f ? 1 : 0;
        break;
      case OP_JALR:
        is_call = (inst & 0xfff) != 0x00000067 ? 1 : 0;
        break;
      default:
        break;
      }
      break;
    }
  }

  if (is_call || is_ret)
  {
    Ftrace *e = &ftracebuf[ftracehead];
    e->pc = pc;
    e->npc = npc;
    e->inst = inst;
    e->intr_cause = intr_cause;
    e->ret = is_ret != 0;
    if (is_call)
    {
      e->depth = ftracedepth;
      ftracedepth++;
    }
    else
    {
      ftracedepth--;
      e->depth = ftracedepth;
    }
    if (ftracedepth > ftracedepth_max)
      ftracedepth_max = ftracedepth;
    ftracehead = (ftracehead + 1) % MAX_FTRACE_SIZE;
  }

  if (ftracedepth < 0)
  {
    /* Many standalone programs (incl. RISCOF compliance tests) don't
     * maintain a balanced call/ret pattern — they tail-call into trap
     * handlers, ret out of M-mode startup via mret, etc.  Instead of
     * hard-exiting on depth<0, clamp to 0 and continue.  This was
     * previously an exit(0) that silently killed NEMU before signature
     * dump or finisher processing could run. */
    static int warned = 0;
    if (!warned)
    {
      Log(ANSI_FMT("ftrace depth negative (%d); clamping to 0 (future warnings suppressed)", ANSI_FG_YELLOW),
          ftracedepth);
      warned = 1;
    }
    ftracedepth = 0;
  }
#else
#error "Unsupported ISA"
#endif
}

/* Lazy formatter: rebuild the short mnemonic + (if CONFIG_ITRACE)
 * Capstone disassembly for one ftrace entry. Called only from
 * cpu_show_ftrace(), so the per-instruction hot path stays free of
 * sprintf and Capstone. */
static void ftrace_format(const Ftrace *e, char *out, size_t out_sz)
{
  const char *mnem = "";
  if (e->intr_cause != INTR_EMPTY)
  {
    snprintf(out, out_sz, "intr: " FMT_WORD, e->intr_cause);
    return;
  }
  switch (e->inst)
  {
  case INST_ECALL:
    mnem = "ecall";
    break;
  case INST_EBREAK:
    mnem = "ebreak";
    break;
  case INST_RET_:
    mnem = "ret";
    break;
  case INST_MRET:
    mnem = "mret";
    break;
  case INST_SRET:
    mnem = "sret";
    break;
  default:
    switch ((uint32_t)(e->inst & 0x7f))
    {
    case OP_JAL_:
      mnem = "jal";
      break;
    case OP_JALR:
      mnem = "jalr";
      break;
    default:
      mnem = "?";
      break;
    }
    break;
  }
#ifdef CONFIG_ITRACE
  int n = snprintf(out, out_sz, "%s ", mnem);
  if (n < 0 || (size_t)n >= out_sz)
    return;
  void disassemble(char *str, int size, uint64_t pc, uint8_t *code, int nbyte);
  uint32_t inst32 = (uint32_t)e->inst;
  disassemble(out + n, (int)(out_sz - n), e->pc, (uint8_t *)&inst32, 4);
#else
  snprintf(out, out_sz, "%s", mnem);
#endif
}

void cpu_show_ftrace(void)
{
  Elf_Sym *sym = NULL;
  Ftrace *ftrace = NULL;
  char buf[128];
  printf("ftrace max depth: %d\n", ftracedepth_max);
  for (size_t i = 0; i < ftracehead; i++)
  {
    ftrace = ftracebuf + i;
    ftrace_format(ftrace, buf, sizeof(buf));
    printf("" FMT_WORD_NO_PREFIX
           " -> " FMT_WORD_NO_PREFIX ": ",
           ftrace->pc, ftrace->npc);
    for (size_t j = 0; j < (ftrace->depth % 16); j++)
    {
      printf(" ");
    }
    printf("%u ", (uint32_t)ftrace->depth);
    printf("%c (" FMT_WORD_NO_PREFIX "): %s ", ftrace->ret ? '<' : '>',
           ftrace->inst, buf);
    if (elfshdr_symtab == NULL)
    {
      printf("\n");
      continue;
    }
    for (int j = elfshdr_symtab->sh_size / sizeof(Elf_Sym) - 1; j >= 0; j--)
    {
      sym = (Elf_Sym *)(elfbuf + elfshdr_symtab->sh_offset + j * sizeof(Elf_Sym));
      if (sym->st_value == ftrace->npc)
      {
        break;
      }
    }
    printf(
        "[%s@" FMT_WORD "]\n",
        elfbuf + elfshdr_strtab->sh_offset + sym->st_name,
        ftrace->npc);
  }
}

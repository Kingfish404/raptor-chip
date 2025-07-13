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
  INST_RET = 0x00008067,
  INST_EBREAK = 0x00100073,
} rv_inst_t;

typedef enum
{
  OP_JAL = 0b1101111,
  OP_JALR = 0b1100111,
} rv_opcode_t;

typedef struct Ftrace
{
  word_t pc;
  word_t npc;
  word_t depth;
  word_t inst;
  char logbuf[128];
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
  if (cpu.raise_intr != INTR_EMPTY)
  {
    sprintf(ftracebuf[ftracehead].logbuf, "intr: %d", cpu.raise_intr);
    is_call = 1;
    during_intr_trap = 1;
    cpu.raise_intr = INTR_EMPTY;
  }
  else
  {
    switch (inst)
    {
    case INST_ECALL:
      sprintf(ftracebuf[ftracehead].logbuf, "ecall");
      is_call = 1;
      break;
    case INST_EBREAK:
      sprintf(ftracebuf[ftracehead].logbuf, "ebreak");
      is_call = 1;
      break;
    case INST_RET:
      sprintf(ftracebuf[ftracehead].logbuf, "ret");
      is_ret = 1;
      break;
    case INST_MRET:
      sprintf(ftracebuf[ftracehead].logbuf, "mret");
      is_ret = during_intr_trap;
      during_intr_trap = 0;
      break;
    case INST_SRET:
      sprintf(ftracebuf[ftracehead].logbuf, "sret");
      is_ret = during_intr_trap;
      during_intr_trap = 0;
      break;
    default:
      switch (opcode)
      {
      case OP_JAL:
        sprintf(ftracebuf[ftracehead].logbuf, "jal");
        is_call = (inst & 0xfff) != 0x0000006f ? 1 : 0;
        break;
      case OP_JALR:
        sprintf(ftracebuf[ftracehead].logbuf, "jalr");
        is_call = (inst & 0xfff) != 0x00000067 ? 1 : 0;
        break;
      default:
        is_call = 0;
        break;
      }
      break;
    }
  }
  if (is_call || is_ret)
  {
    ftracebuf[ftracehead].inst = inst;
#ifdef CONFIG_ITRACE
    char *p = ftracebuf[ftracehead].logbuf;
    void disassemble(char *str, int size, uint64_t pc, uint8_t *code, int nbyte);
    disassemble(p, ftracebuf[ftracehead].logbuf + sizeof(ftracebuf[ftracehead].logbuf) - p,
                pc, (uint8_t *)&inst, 4);
#endif
  }
  if (is_call)
  {
    ftracebuf[ftracehead].pc = pc;
    ftracebuf[ftracehead].npc = npc;
    ftracebuf[ftracehead].ret = false;
    ftracebuf[ftracehead].depth = ftracedepth;
    ftracedepth++;
  }
  else if (is_ret)
  {
    ftracebuf[ftracehead].pc = pc;
    ftracebuf[ftracehead].npc = npc;
    ftracebuf[ftracehead].ret = true;
    ftracedepth--;
    ftracebuf[ftracehead].depth = ftracedepth;
  }
  if (ftracedepth > ftracedepth_max)
  {
    ftracedepth_max = ftracedepth;
  }
  if (is_call || is_ret)
  {
    ftracehead = (ftracehead + 1) % MAX_FTRACE_SIZE;
  }
  if (ftracedepth < 0)
  {
    cpu_show_ftrace();
    Log(ANSI_FMT("ftrace depth negative (%d)", ANSI_FG_RED),
        ftracedepth);
    exit(0);
  }
#else
#error "Unsupported ISA"
#endif
}

void cpu_show_ftrace(void)
{
  Elf_Sym *sym = NULL;
  Ftrace *ftrace = NULL;
  printf("ftrace max depth: %d\n", ftracedepth_max);
  for (size_t i = 0; i < ftracehead; i++)
  {
    ftrace = ftracebuf + i;
    printf("" FMT_WORD_NO_PREFIX
           " -> " FMT_WORD_NO_PREFIX ": ",
           ftrace->pc, ftrace->npc);
    for (size_t j = 0; j < (ftrace->depth % 16); j++)
    {
      printf(" ");
    }
    printf("%d ", ftrace->depth);
    printf("%c (%08x): %s ", ftrace->ret ? '<' : '>',
           ftrace->inst, ftrace->logbuf);
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

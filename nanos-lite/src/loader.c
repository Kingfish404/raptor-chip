#include <proc.h>
#include <elf.h>
#include <fs.h>

#ifdef __LP64__
#define Elf_Ehdr Elf64_Ehdr
#define Elf_Phdr Elf64_Phdr
#else
#define Elf_Ehdr Elf32_Ehdr
#define Elf_Phdr Elf32_Phdr
#endif

#define FMT_WORD "0x%x"

size_t ramdisk_read(void *buf, size_t offset, size_t len);

static uintptr_t loader(PCB *pcb, const char *filename)
{
  Elf_Ehdr elf_ehdr;
  int fd = fs_open(filename, 0, 0);
  fs_read(fd, &elf_ehdr, sizeof(elf_ehdr));
  assert(*(uint32_t *)elf_ehdr.e_ident == 0x464c457f);
#ifdef __ISA_X86__
  assert(elf_ehdr.e_machine == EM_X86_64);
#elif __riscv
  assert(elf_ehdr.e_machine == EM_RISCV);
#else
  assert(0);
#endif

  uintptr_t entry = elf_ehdr.e_entry;
  Elf_Phdr elf_phdr;
  for (size_t i = 0; i < elf_ehdr.e_phnum; i++)
  {
    fs_lseek(fd, elf_ehdr.e_phoff + i * elf_ehdr.e_phentsize, SEEK_SET);
    fs_read(fd, &elf_phdr, sizeof(elf_phdr));
    if (elf_phdr.p_type == PT_LOAD)
    {
      uintptr_t pa = elf_phdr.p_paddr;
      fs_lseek(fd, elf_phdr.p_offset, SEEK_SET);
      fs_read(fd, (void *)pa, elf_phdr.p_filesz);
      memset((void *)(pa + elf_phdr.p_filesz), 0, elf_phdr.p_memsz - elf_phdr.p_filesz);
    }
  }
  return entry;
}

void context_uload(PCB *pcb, const char *filename)
{
  void *entry = loader(pcb, filename);
  pcb->cp = ucontext(NULL, (Area){pcb->stack, pcb->stack + STACK_SIZE}, entry);
  pcb->cp->GPRx = (uintptr_t)&pcb->stack[STACK_SIZE];
  printf("GPRx: %x\n", pcb->cp->GPRx);
}

void naive_uload(PCB *pcb, const char *filename)
{
  uintptr_t entry = loader(pcb, filename);
  Log("Jump to entry = %p", entry);
  ((void (*)())entry)();
}

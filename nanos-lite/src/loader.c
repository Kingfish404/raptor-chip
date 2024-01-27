#include <proc.h>
#include <elf.h>

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
  ramdisk_read(&elf_ehdr, 0, sizeof(elf_ehdr));
  assert(*(uint32_t *)elf_ehdr.e_ident == 0x464c457f);
  uintptr_t entry = elf_ehdr.e_entry;
  for (size_t i = 0; i < elf_ehdr.e_phnum; i++)
  {
    Elf_Phdr elf_phdr;
    ramdisk_read(&elf_phdr, elf_ehdr.e_phoff + i * elf_ehdr.e_phentsize, sizeof(elf_phdr));
    if (elf_phdr.p_type == PT_LOAD)
    {
      uintptr_t pa = elf_phdr.p_paddr;
      ramdisk_read((void *)pa, elf_phdr.p_offset, elf_phdr.p_filesz);
      memset((void *)(pa + elf_phdr.p_filesz), 0, elf_phdr.p_memsz - elf_phdr.p_filesz);
    }
  }
  return entry;
}

void naive_uload(PCB *pcb, const char *filename)
{
  uintptr_t entry = loader(pcb, filename);
  Log("Jump to entry = %p", entry);
  ((void (*)())entry)();
}

// Memory-backed ELF loader for embedded payloads.
// Loads an ELF from a memory buffer (e.g., .incbin payload) instead of
// from the HTIF filesystem.

#include "pk.h"
#include "elf.h"
#include "boot.h"
#include "mmap.h"
#include "usermem.h"
#include "bits.h"
#include "elf_mem.h"
#include <string.h>

static inline int get_prot_mem(uint32_t p_flags)
{
  int prot_x = (p_flags & PF_X) ? PROT_EXEC : PROT_NONE;
  int prot_w = (p_flags & PF_W) ? PROT_WRITE : PROT_NONE;
  int prot_r = (p_flags & PF_R) ? PROT_READ : PROT_NONE;
  return (prot_x | prot_w | prot_r);
}

void load_elf_mem(const void *elf_data, size_t elf_size, elf_info *info)
{
  const Elf_Ehdr *eh = (const Elf_Ehdr *)elf_data;

  if (elf_size < sizeof(Elf_Ehdr) ||
      !(eh->e_ident[0] == '\177' && eh->e_ident[1] == 'E' &&
        eh->e_ident[2] == 'L' && eh->e_ident[3] == 'F'))
    panic("invalid ELF payload");

#if __riscv_xlen == 64
  kassert(IS_ELF64(*eh));
#else
  kassert(IS_ELF32(*eh));
#endif

  size_t phdr_size = eh->e_phnum * sizeof(Elf_Phdr);
  if (phdr_size > info->phdr_size)
    panic("too many program headers");

  memcpy((void *)info->phdr, (const char *)elf_data + eh->e_phoff, phdr_size);
  info->phnum = eh->e_phnum;
  info->phent = sizeof(Elf_Phdr);
  Elf_Phdr *ph = (Elf_Phdr *)info->phdr;

  // Compute highest VA
  uintptr_t max_vaddr = 0;
  for (int i = 0; i < eh->e_phnum; i++)
    if (ph[i].p_type == PT_LOAD && ph[i].p_memsz)
      max_vaddr = MAX(max_vaddr, ph[i].p_vaddr + ph[i].p_memsz);
  max_vaddr = ROUNDUP(max_vaddr, RISCV_PGSIZE);

  uintptr_t bias = 0;
  if (eh->e_type == ET_DYN)
    bias = RISCV_PGSIZE;

  info->entry = eh->e_entry + bias;
  int flags = MAP_FIXED | MAP_PRIVATE | MAP_ANONYMOUS;

  for (int i = eh->e_phnum - 1; i >= 0; i--)
  {
    if (ph[i].p_type == PT_INTERP)
      panic("not a statically linked ELF program");

    if (ph[i].p_type == PT_LOAD && ph[i].p_memsz)
    {
      if (ph[i].p_filesz > ph[i].p_memsz)
        panic("invalid ELF segment");

      uintptr_t prepad = ph[i].p_vaddr % RISCV_PGSIZE;
      uintptr_t vaddr = ph[i].p_vaddr + bias;

      if (vaddr + ph[i].p_memsz > info->brk_min)
        info->brk_min = vaddr + ph[i].p_memsz;

      int prot = get_prot_mem(ph[i].p_flags);

      // Map anonymous memory for the entire segment
      uintptr_t map_addr = vaddr - prepad;
      size_t map_size = ROUNDUP(ph[i].p_memsz + prepad, RISCV_PGSIZE);
      uintptr_t result = __do_mmap(map_addr, map_size,
                                   prot | PROT_WRITE,
                                   flags | MAP_POPULATE, 0, 0);
      if (result != map_addr)
        panic("mmap failed for ELF segment");

      // Zero prepad area
      if (prepad)
        memset_user((void *)map_addr, 0, prepad);

      // Copy file data from embedded ELF
      if (ph[i].p_filesz > 0)
      {
        const void *src = (const char *)elf_data + ph[i].p_offset;
        memcpy_to_user((void *)vaddr, src, ph[i].p_filesz);
      }

      // Zero BSS (memsz > filesz)
      if (ph[i].p_memsz > ph[i].p_filesz)
      {
        memset_user((void *)(vaddr + ph[i].p_filesz), 0,
                    ph[i].p_memsz - ph[i].p_filesz);
      }

      // Restore final protection
      if (!(prot & PROT_WRITE))
        do_mprotect(map_addr, map_size, prot);
    }
  }

  // Set up mmap region
  info->mmap_max = (eh->e_type == ET_DYN)
                       ? (max_vaddr + bias + RISCV_PGSIZE)
                       : 0;
  if (!info->mmap_max)
  {
    uintptr_t brk_page = ROUNDUP(info->brk_min, RISCV_PGSIZE);
    info->mmap_max = MAX(brk_page + 0x10000000, max_vaddr);
  }

  info->brk_max = info->brk_min;
}

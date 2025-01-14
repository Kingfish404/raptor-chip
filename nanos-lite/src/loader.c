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
      uintptr_t start_aligned = elf_phdr.p_vaddr & ~(PGSIZE - 1);
      int n_pages = ((elf_phdr.p_memsz + elf_phdr.p_vaddr - start_aligned + PGSIZE - 1) / PGSIZE) + 1;
      void *page = new_page(n_pages);
      void *page_start = page + (elf_phdr.p_vaddr - start_aligned);
      fs_lseek(fd, elf_phdr.p_offset, SEEK_SET);
      fs_read(fd, (void *)page_start, elf_phdr.p_filesz);
      memset((page_start + elf_phdr.p_filesz), 0, elf_phdr.p_memsz - elf_phdr.p_filesz);
      for (int j = 0; j < n_pages; j++)
      {
        map(&pcb->as,
            (void *)(start_aligned + j * PGSIZE),
            page + j * PGSIZE,
            (PTE_A | PTE_D | PTE_R | PTE_W | PTE_X | PTE_U));
      }
      pcb->max_brk = (uintptr_t)(start_aligned + n_pages * PGSIZE);
    }
  }
  fs_close(fd);
  return entry;
}

void naive_uload(PCB *pcb, const char *filename)
{
  uintptr_t entry = loader(pcb, filename);
  Log("Jump to entry = %p", entry);
  ((void (*)())entry)();
}

void context_kload(PCB *pcb, void *entry, void *arg)
{
  pcb->cp = kcontext((Area){pcb->stack, pcb->stack + STACK_SIZE}, entry, arg);
}

void context_uload(PCB *pcb, const char *filename, char *const argv[], char *const envp[])
{
  protect(&pcb->as);
  uintptr_t entry = loader(pcb, filename);
  int argc = 0, envp_size = 0;
  while (argv[argc] != NULL)
  {
    argc++;
  }
  if (envp == NULL)
  {
    envp = (char *const[]){NULL};
  }
  while (envp[envp_size] != NULL)
  {
    envp_size++;
  }
  Log("Jump to entry = %p, argc = %d, envp_size = %d", entry, argc, envp_size);
  envp_size = 0; // TODO: fixme for pal
  char *argv_table[argc + 1], *envp_table[envp_size + 1];
  int argv_sizes[argc], envp_sizes[envp_size];
  for (int i = 0; i < argc; i++)
  {
    for (int j = 0; argv[i][j] != '\0'; j++)
    {
      argv_sizes[i] = j;
    }
    argv_sizes[i] += 2;
  }
  for (int i = 0; i < envp_size; i++)
  {
    for (int j = 0; envp[i][j] != '\0'; j++)
    {
      envp_sizes[i] = j;
    }
    envp_sizes[i] += 2;
  }
  const Area kstack = (Area){.start = pcb->stack, .end = pcb->stack + STACK_SIZE};
  pcb->cp = ucontext(&pcb->as, kstack, (void *)entry);
  void *const ustack_s = new_page(8);
  void *const ustack_end = ustack_s + 8 * PGSIZE;
  for (int i = 0; i < 8; i++)
  {
    map(&pcb->as,
        (void *)pcb->as.area.end - 8 * PGSIZE + i * PGSIZE,
        (void *)ustack_s + i * PGSIZE,
        (PTE_A | PTE_D | PTE_R | PTE_W | PTE_U));
  }
  void *sp = ustack_s + 8 * PGSIZE;
  // Unspecified area
  sp -= 4 * sizeof(int);
  // string area: argv[]
  for (int i = argc - 1; i >= 0; i--)
  {
    sp -= argv_sizes[i] + 1;
    sp = (void *)((uintptr_t)sp & ~15);
    for (int j = 0; j < argv_sizes[i] - 1; j++)
    {
      *(char *)(sp + j) = argv[i][j];
    }
    *(char *)(sp + argv_sizes[i] - 1) = '\0';
    argv_table[i] = sp;
  }
  // string area: envp[]
  for (int i = envp_size - 1; i >= 0; i--)
  {
    sp -= envp_sizes[i] + 1;
    sp = (void *)((uintptr_t)sp & ~15);
    for (int j = 0; j < envp_sizes[i] - 1; j++)
    {
      *(char *)(sp + j) = envp[i][j];
    }
    *(char *)(sp + envp_sizes[i] - 1) = '\0';
    envp_table[i] = (char *)sp;
  }
  // NULL
  sp -= sizeof(size_t);
  sp = (void *)((uintptr_t)sp & ~15);
  *(char **)sp = NULL;
  // envp[]
  for (int i = envp_size - 1; i >= 0; i--)
  {
    sp -= sizeof(char *);
    *(char **)sp = (char *)envp_table[i];
  }
  // argv[]
  for (int i = argc - 1; i >= 0; i--)
  {
    sp -= sizeof(char *);
    *(char **)sp = argv_table[i];
  }
  // argc
  sp -= sizeof(int);
  *(int *)sp = argc;
  pcb->cp->gpr[r_a0] = (uintptr_t)sp;
}

#ifndef _ELF_MEM_H
#define _ELF_MEM_H

#include "boot.h"
#include <stddef.h>

void load_elf_mem(const void *elf_data, size_t elf_size, elf_info *info);

#endif

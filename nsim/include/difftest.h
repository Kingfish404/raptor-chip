#ifndef __NPC_DIFFTEST_H__
#define __NPC_DIFFTEST_H__

#include <common.h>

void difftest_skip_ref();

void difftest_skip_dut(int nr_ref, int nr_dut);

void difftest_raise_intr(uint64_t NO);

void difftest_step(vaddr_t pc);

void init_difftest(char *ref_so_file, long img_size, int port);

#endif /* __NPC_DIFFTEST_H__ */
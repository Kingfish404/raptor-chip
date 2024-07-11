#include <common.h>
#include <string.h>

extern NPCState npc;

const char *regs[] = {
    "$0", "ra", "sp", "gp", "tp", "t0", "t1", "t2",
    "s0", "s1", "a0", "a1", "a2", "a3", "a4", "a5",
    "a6", "a7", "s2", "s3", "s4", "s5", "s6", "s7",
    "s8", "s9", "s10", "s11", "t3", "t4", "t5", "t6"};

int reg_str2idx(const char *reg)
{
    for (size_t i = 0; i < GPR_SIZE; i++)
    {
        if (strcmp(reg, regs[i]) == 0)
            return i;
    }
    return -1;
}

void reg_display(int n)
{
    printf(" pc: " FMT_GREEN(FMT_WORD_NO_PREFIX) "\n",
           *(npc.pc));
    for (size_t i = 0; i < n; i++)
    {
        if (i != 0 && i % 4 == 0)
            printf("\n");
        printf("%3s: " FMT_WORD_NO_PREFIX " ", regs[i], npc.gpr[i]);
    }
    printf("\n");
    printf("npc.csr.mcause: " FMT_WORD_NO_PREFIX "\n", *npc.mcause);
    printf("npc.csr.mepc: " FMT_WORD_NO_PREFIX "\n", *npc.mepc);
    printf("npc.csr.mtvec: " FMT_WORD_NO_PREFIX "\n", *npc.mtvec);
    printf("npc.csr.mstatus: " FMT_WORD_NO_PREFIX "\n", *npc.mstatus);
}

void isa_parser_elf(char *filename)
{
}
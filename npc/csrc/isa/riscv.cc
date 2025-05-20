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
    printf(" sstatus: " FMT_WORD_NO_PREFIX " ", *npc.sstatus);
    printf("     sie: " FMT_WORD_NO_PREFIX " ", *npc.sie____);
    printf("   stvec: " FMT_WORD_NO_PREFIX "\n", *npc.stvec__);

    printf("sscratch: " FMT_WORD_NO_PREFIX " ", *npc.sscratch);
    printf("    sepc: " FMT_WORD_NO_PREFIX " ", *npc.sepc___);
    printf("  scause: " FMT_WORD_NO_PREFIX "\n", *npc.scause_);
    printf("   stval: " FMT_WORD_NO_PREFIX " ", *npc.stval__);
    printf("     sip: " FMT_WORD_NO_PREFIX " ", *npc.sip____);
    printf("    satp: " FMT_WORD_NO_PREFIX "\n", *npc.satp___);

    printf(" mstatus: " FMT_WORD_NO_PREFIX " ", *npc.mstatus);
    printf(" medeleg: " FMT_WORD_NO_PREFIX " ", *npc.medeleg);
    printf(" mideleg: " FMT_WORD_NO_PREFIX "\n", *npc.mideleg);
    printf("     mie: " FMT_WORD_NO_PREFIX " ", *npc.mie____);
    printf("   mtvec: " FMT_WORD_NO_PREFIX "\n", *npc.mtvec__);

    printf("mscratch: " FMT_WORD_NO_PREFIX " ", *npc.mscratch);
    printf("    mepc: " FMT_WORD_NO_PREFIX " ", *npc.mepc___);
    printf("  mcause: " FMT_WORD_NO_PREFIX "\n", *npc.mcause_);
    printf("   mtval: " FMT_WORD_NO_PREFIX " ", *npc.mtval__);
    printf("     mip: " FMT_WORD_NO_PREFIX "\n", *npc.mip____);
    for (size_t i = 0; i < n; i++)
    {
        if (i != 0 && i % 4 == 0)
            printf("\n");
        printf("%3s: " FMT_WORD_NO_PREFIX " ", regs[i], npc.gpr[i]);
    }
    printf("\n");
}

void isa_parser_elf(char *filename)
{
}
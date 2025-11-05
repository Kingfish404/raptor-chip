#include <common.h>
#include <string.h>

#include <stdio.h>

NPCState npc = {
    .state = NPC_RUNNING,
    .gpr = NULL,
    .ret = NULL,
    .pc = NULL,

    .inst = NULL,

    .soc_sram = NULL,
};

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
    printf(" pc: " FMT_GREEN(FMT_WORD) ", priv: %d\n",
           *(npc.pc), *(npc.priv));
    printf(" sstatus: " FMT_WORD " ", *npc.sstatus);
    printf("     sie: " FMT_WORD " ", *npc.sie____);
    printf("   stvec: " FMT_WORD "\n", *npc.stvec__);

    printf("sscratch: " FMT_WORD " ", *npc.sscratch);
    printf("    sepc: " FMT_WORD " ", *npc.sepc___);
    printf("  scause: " FMT_WORD "\n", *npc.scause_);
    printf("   stval: " FMT_WORD " ", *npc.stval__);
    printf("     sip: " FMT_WORD "\n", *npc.sip____);
    printf("    satp: " FMT_WORD "\n", *npc.satp___);

    printf(" mstatus: " FMT_WORD " ", *npc.mstatus);
    printf("     mie: " FMT_WORD " ", *npc.mie____);
    printf("   mtvec: " FMT_WORD "\n", *npc.mtvec__);

    printf("mscratch: " FMT_WORD " ", *npc.mscratch);
    printf("    mepc: " FMT_WORD " ", *npc.mepc___);
    printf("  mcause: " FMT_WORD "\n", *npc.mcause_);
    printf("   mtval: " FMT_WORD " ", *npc.mtval__);
    printf("     mip: " FMT_WORD "\n", *npc.mip____);
    printf(" medeleg: " FMT_WORD " ", *npc.medeleg);
    printf(" mideleg: " FMT_WORD "\n", *npc.mideleg);

    for (size_t i = 0; i < n; i++)
    {
        if (i != 0 && i % 4 == 0)
            printf("\n");
        printf("%3s: " FMT_WORD " ", regs[i], npc.gpr[i]);
    }
    printf("\n");
}

void isa_parser_elf(char *filename)
{
}

int isa_save_uarch_state(const char *filename)
{
    if (filename == NULL)
    {
        return -1;
    }
    FILE *fp = fopen(filename, "w");
    if (fp == NULL)
    {
        return -1;
    }
    // save NPCState in json format
    fprintf(fp, "{\n");
    fprintf(fp, "  \"rpc\": \"" FMT_WORD "\",\n", *(npc.rpc));
    fprintf(fp, "  \"npc\": \"" FMT_WORD "\",\n", *(npc.pc));
    fprintf(fp, "  \"priv\": %d,\n", *(npc.priv));
    fprintf(fp, "  \"gpr\": [\n");
    for (size_t i = 0; i < GPR_SIZE; i++)
    {
        fprintf(fp, "    \"" FMT_WORD "\"%s\n", npc.gpr[i], (i == GPR_SIZE - 1) ? "" : ",");
    }
    fprintf(fp, "  ],\n");
    // csr
    fprintf(fp, "  \"csr\": {\n");
    fprintf(fp, "    \"sstatus\": \"" FMT_WORD "\",\n", *npc.sstatus);
    fprintf(fp, "    \"sie\": \"" FMT_WORD "\",\n", *npc.sie____);
    fprintf(fp, "    \"stvec\": \"" FMT_WORD "\",\n", *npc.stvec__);

    fprintf(fp, "    \"sscratch\": \"" FMT_WORD "\",\n", *npc.sscratch);
    fprintf(fp, "    \"sepc\": \"" FMT_WORD "\",\n", *npc.sepc___);
    fprintf(fp, "    \"scause\": \"" FMT_WORD "\",\n", *npc.scause_);
    fprintf(fp, "    \"stval\": \"" FMT_WORD "\",\n", *npc.stval__);
    fprintf(fp, "    \"sip\": \"" FMT_WORD "\",\n", *npc.sip____);
    fprintf(fp, "    \"satp\": \"" FMT_WORD "\",\n", *npc.satp___);

    fprintf(fp, "    \"mstatus\": \"" FMT_WORD "\",\n", *npc.mstatus);
    fprintf(fp, "    \"medeleg\": \"" FMT_WORD "\",\n", *npc.medeleg);
    fprintf(fp, "    \"mideleg\": \"" FMT_WORD "\",\n", *npc.mideleg);
    fprintf(fp, "    \"mie\": \"" FMT_WORD "\",\n", *npc.mie____);
    fprintf(fp, "    \"mtvec\": \"" FMT_WORD "\",\n", *npc.mtvec__);

    fprintf(fp, "    \"mscratch\": \"" FMT_WORD "\",\n", *npc.mscratch);
    fprintf(fp, "    \"mepc\": \"" FMT_WORD "\",\n", *npc.mepc___);
    fprintf(fp, "    \"mcause\": \"" FMT_WORD "\",\n", *npc.mcause_);
    fprintf(fp, "    \"mtval\": \"" FMT_WORD "\",\n", *npc.mtval__);
    fprintf(fp, "    \"mip\": \"" FMT_WORD "\",\n", *npc.mip____);
    fprintf(fp, "  }\n");
    fprintf(fp, "}");

    fclose(fp);

    return 0;
}

int isa_load_uarch_state(const char *filename)
{
    if (filename == NULL)
    {
        return -1;
    }
    FILE *fp = fopen(filename, "r");
    if (fp == NULL)
    {
        return -1;
    }

#if defined(__LOAD_STATE___)
    fscanf(fp, "{");
    fscanf(fp, "  \"rpc\": \"" FMT_WORD "\",\n", (npc.rpc));
    fscanf(fp, "  \"npc\": \"" FMT_WORD "\",\n", (npc.pc));
    fscanf(fp, "  \"priv\": %d,\n", (int *)(npc.priv));
    fscanf(fp, "  \"gpr\": [");
    for (size_t i = 0; i < GPR_SIZE; i++)
    {
        if (i != GPR_SIZE - 1)
        {
            fscanf(fp, "    \"" FMT_WORD "\",\n", &(npc.gpr[i]));
        }
        else
        {
            fscanf(fp, "    \"" FMT_WORD "\"\n", &(npc.gpr[i]));
        }
    }
    fscanf(fp, "  ],");
    // csr
    fscanf(fp, "  \"csr\": {");
    fscanf(fp, "    \"sstatus\": \"" FMT_WORD "\",\n", (npc.sstatus));
    fscanf(fp, "    \"sie\": \"" FMT_WORD "\",\n", (npc.sie____));
    fscanf(fp, "    \"stvec\": \"" FMT_WORD "\",\n", (npc.stvec__));

    fscanf(fp, "    \"sscratch\": \"" FMT_WORD "\",\n", (npc.sscratch));
    fscanf(fp, "    \"sepc\": \"" FMT_WORD "\",\n", (npc.sepc___));
    fscanf(fp, "    \"scause\": \"" FMT_WORD "\",\n", (npc.scause_));
    fscanf(fp, "    \"stval\": \"" FMT_WORD "\",\n", (npc.stval__));
    fscanf(fp, "    \"sip\": \"" FMT_WORD "\",\n", (npc.sip____));
    fscanf(fp, "    \"satp\": \"" FMT_WORD "\",\n", (npc.satp___));

    fscanf(fp, "    \"mstatus\": \"" FMT_WORD "\",\n", (npc.mstatus));
    fscanf(fp, "    \"medeleg\": \"" FMT_WORD "\",\n", (npc.medeleg));
    fscanf(fp, "    \"mideleg\": \"" FMT_WORD "\",\n", (npc.mideleg));
    fscanf(fp, "    \"mie\": \"" FMT_WORD "\",\n", (npc.mie____));
    fscanf(fp, "    \"mtvec\": \"" FMT_WORD "\",\n", (npc.mtvec__));

    fscanf(fp, "    \"mscratch\": \"" FMT_WORD "\",\n", (npc.mscratch));
    fscanf(fp, "    \"mepc\": \"" FMT_WORD "\",\n", (npc.mepc___));
    fscanf(fp, "    \"mcause\": \"" FMT_WORD "\",\n", (npc.mcause_));
    fscanf(fp, "    \"mtval\": \"" FMT_WORD "\",\n", (npc.mtval__));
    fscanf(fp, "    \"mip\": \"" FMT_WORD "\",\n", (npc.mip____));
    fscanf(fp, "  }");
    fscanf(fp, "}");
#endif

    fclose(fp);
    return 0;
}
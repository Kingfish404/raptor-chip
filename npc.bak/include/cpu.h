#ifndef __NPC_CPU_H__
#define __NPC_CPU_H__

enum CSR_REGISTER
{
    CSR_MCAUSE = 0x1,
    CSR_MEPC = 0x2,
    CSR_MTVEC = 0x3,
    CSR_MSTATUS = 0x4,
};

void cpu_exec_init();

void cpu_exec(uint64_t n);

void cpu_show_itrace();

#endif /* __NPC_CPU_H__ */
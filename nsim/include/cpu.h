#ifndef __NPC_CPU_H__
#define __NPC_CPU_H__

typedef enum
{
    MNONE__ = 0,

    SSTATUS,
    SIE____,
    STVEC__,

    SCOUNTE,

    SSCRATCH,
    SEPC___,
    SCAUSE_,
    STVAL__,
    SIP____,
    SATP___,

    MSTATUS,
    MISA___,
    MEDELEG,
    MIDELEG,
    MIE____,
    MTVEC__,

    MSTATUSH,

    MSCRATCH,
    MEPC___,
    MCAUSE_,
    MTVAL__,
    MIP____,

    MCYCLE_,
    TIME___,
    TIMEH__
} csr_t;

void cpu_exec_init();

void cpu_exec(uint64_t n);

void cpu_show_itrace();

#endif /* __NPC_CPU_H__ */
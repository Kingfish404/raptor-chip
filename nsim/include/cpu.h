#ifndef __NPC_CPU_H__
#define __NPC_CPU_H__

typedef enum
{
    MNONE__ = 0,

    SSTATUS,
    SIE____,
    STVEC__,

    MCOUNTE,
    // Map it to MCOUNTE so indices stay aligned.
    SCOUNTE = MCOUNTE,

    SSCRATCH,
    SEPC___,
    SCAUSE_,
    STVAL__,
    SIP____,
    STIMECMP,
    STIMECMPH,
    SATP___,

    MSTATUS,
    MISA___,
    MEDELEG,
    MIDELEG,
    MIE____,
    MTVEC__,

    MSTATUSH,
    MENVCFG,

    MSCRATCH,
    MEPC___,
    MCAUSE_,
    MTVAL__,
    MIP____,

    MCYCLE_,
    MCYCLEH,
    MINSTRET,
    MINSTRETH,
    TIME___,
    TIMEH__,

    MVENDORID,
    MARCHID,
    IMPID__,
    MHARTID
} csr_t;

void cpu_exec_init();

void cpu_exec(uint64_t n);

void cpu_show_itrace();

#endif /* __NPC_CPU_H__ */
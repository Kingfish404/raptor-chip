#include <common.h>

extern NPCState npc;

void nsim_plic_raise(uint32_t irq)
{
    if (irq == 0 || irq > NPC_PLIC_NDEV)
        return;
    if (npc.plic_pending != NULL)
        *npc.plic_pending |= (1u << irq);
}
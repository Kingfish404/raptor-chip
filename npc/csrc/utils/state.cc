#include <common.h>

int is_exit_status_bad()
{
    int good = ((npc.state == NPC_END && *(npc.ret) == EXIT_SUCCESS) ||
                (npc.state == NPC_QUIT));
    return !good;
}
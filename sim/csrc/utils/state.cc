#include <common.h>
#include <memory.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern NPCState npc;

int is_exit_status_bad()
{
    int good = ((npc.state == NPC_END && (npc.host_exit_ok || *(npc.ret) == EXIT_SUCCESS)) ||
                (npc.state == NPC_QUIT));
    return !good;
}

/* ===== RISC-V signature dump (for RISCOF compliance testing) ===== */
/* Configured via --sig=<hex_begin>-<hex_end>:<path> option.
 * Dumps memory[sig_begin, sig_end) as 4-byte little-endian words, one word
 * per line as 8 lowercase hex chars, matching the RISC-V architecture test
 * signature format produced by reference models such as Sail. */

static paddr_t sig_begin = 0;
static paddr_t sig_end = 0;
static char *sig_file = NULL;
static int sig_enabled = 0;

int sig_set_range(const char *spec)
{
    if (spec == NULL)
        return -1;
    /* Expected form: <hex_begin>-<hex_end>:<path>                           */
    const char *dash = strchr(spec, '-');
    const char *colon = strchr(spec, ':');
    if (dash == NULL || colon == NULL || dash >= colon)
        return -1;

    unsigned long long begin = 0, end = 0;
    if (sscanf(spec, "%llx-%llx", &begin, &end) != 2)
        return -1;

    sig_begin = (paddr_t)begin;
    sig_end = (paddr_t)end;
    if (sig_end <= sig_begin)
        return -1;

    const char *path = colon + 1;
    if (*path == '\0')
        return -1;
    if (sig_file != NULL)
        free(sig_file);
    sig_file = strdup(path);
    sig_enabled = 1;
    return 0;
}

int sig_dump_if_enabled(void)
{
    if (!sig_enabled)
        return 0;

    FILE *fp = fopen(sig_file, "w");
    if (fp == NULL)
    {
        printf("[sig] ERROR: cannot open signature file: %s\n", sig_file);
        return -1;
    }

    /* Align range up to 4 bytes; RISCOF guarantees 4-byte alignment but be
     * defensive in case of a misconfigured test. */
    paddr_t addr = sig_begin & ~((paddr_t)0x3);
    paddr_t end = (sig_end + 3) & ~((paddr_t)0x3);
    size_t words = 0;

    for (; addr < end; addr += 4)
    {
        uint8_t *host = guest_to_host(addr);
        uint32_t w = 0;
        if (host != NULL)
        {
            /* Little-endian load from host buffer. */
            w = ((uint32_t)host[0]) |
                ((uint32_t)host[1] << 8) |
                ((uint32_t)host[2] << 16) |
                ((uint32_t)host[3] << 24);
        }
        fprintf(fp, "%08x\n", w);
        words++;
    }

    fclose(fp);
    printf("[sig] dumped %zu words [" FMT_WORD ", " FMT_WORD ") -> %s\n",
           words, (word_t)sig_begin, (word_t)sig_end, sig_file);
    return 0;
}
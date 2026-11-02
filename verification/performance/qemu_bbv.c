/* SPDX-License-Identifier: GPL-2.0-or-later */
/* Optional QEMU 8.2+ system-mode BBV frontend. Build against the matching
 * qemu-plugin.h. Counts translation-block instruction weights, not verified
 * retirements; these vectors must not supply NEMU checkpoint instruction IDs. */
#include <qemu-plugin.h>
#include <glib.h>
#include <errno.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

QEMU_PLUGIN_EXPORT int qemu_plugin_version = QEMU_PLUGIN_VERSION;

typedef struct {
    uint64_t pc, physical, instructions, id, count;
} Block;

static GHashTable *blocks;
static FILE *output, *mapping, *timing;
static uint64_t interval = 10000000, counted, next_id, total, intervals;

static guint block_hash(gconstpointer data)
{
    const Block *block = data;
    uint64_t value = block->pc ^ (block->physical << 7) ^ (block->instructions << 23);
    return (guint)(value ^ (value >> 32));
}

static gboolean block_equal(gconstpointer left, gconstpointer right)
{
    const Block *a = left, *b = right;
    return a->pc == b->pc && a->physical == b->physical && a->instructions == b->instructions;
}

static void flush_vector(void)
{
    if (!counted) return;
    fputc('T', output);
    GHashTableIter iterator;
    gpointer key;
    g_hash_table_iter_init(&iterator, blocks);
    while (g_hash_table_iter_next(&iterator, &key, NULL)) {
        Block *block = key;
        if (block->count)
            fprintf(output, ":%" PRIu64 ":%" PRIu64 " ", block->id, block->count);
        block->count = 0;
    }
    fputc('\n', output);
    if (ferror(output) || fflush(output)) abort();
    if (timing) {
        struct timespec now;
        if (clock_gettime(CLOCK_MONOTONIC, &now)) abort();
        uint64_t nanoseconds = (uint64_t)now.tv_sec * 1000000000 + now.tv_nsec;
        fprintf(timing, "{\"schema\":\"qemu-bbv-interval-v1\",\"interval\":%" PRIu64
                ",\"start\":%" PRIu64 ",\"instructions\":%" PRIu64
                ",\"monotonic_ns\":%" PRIu64 "}\n", intervals, total, counted, nanoseconds);
        if (ferror(timing) || fflush(timing)) abort();
    }
    intervals++;
    total += counted;
    counted = 0;
}

static void executed(unsigned int vcpu, void *data)
{
    if (vcpu != 0) abort();
    Block *block = data;
    block->count += block->instructions;
    counted += block->instructions;
    if (counted >= interval) flush_vector();
}

static void translated(qemu_plugin_id_t id, struct qemu_plugin_tb *tb)
{
    (void)id;
    Block key = {.pc = qemu_plugin_tb_vaddr(tb),
                 .instructions = qemu_plugin_tb_n_insns(tb)};
    if (!key.instructions) return;
    key.physical = (uintptr_t)qemu_plugin_insn_haddr(qemu_plugin_tb_get_insn(tb, 0));
    Block *block = g_hash_table_lookup(blocks, &key);
    if (!block) {
        block = g_new0(Block, 1);
        *block = key;
        block->id = ++next_id;
        g_hash_table_insert(blocks, block, block);
        if (mapping)
            fprintf(mapping, "{\"schema\":\"qemu-bbv-block-v1\",\"id\":%" PRIu64
                    ",\"pc\":\"0x%" PRIx64 "\",\"instructions\":%" PRIu64 "}\n",
                    block->id, block->pc, block->instructions);
    }
    qemu_plugin_register_vcpu_tb_exec_cb(tb, executed, QEMU_PLUGIN_CB_NO_REGS, block);
}

static void finished(qemu_plugin_id_t id, void *data)
{
    (void)id;
    (void)data;
    flush_vector();
    if (fclose(output)) abort();
    if (mapping && fclose(mapping)) abort();
    if (timing && fclose(timing)) abort();
    g_hash_table_destroy(blocks);
}

QEMU_PLUGIN_EXPORT int qemu_plugin_install(qemu_plugin_id_t id, const qemu_info_t *info,
                                          int argc, char **argv)
{
    const char *path = NULL, *map_path = NULL, *time_path = NULL;
    if (!info->system_emulation || info->system.smp_vcpus != 1 ||
        strncmp(info->target_name, "riscv", 5)) return -1;
    for (int i = 0; i < argc; i++) {
        if (!strncmp(argv[i], "outfile=", 8)) path = argv[i] + 8;
        else if (!strncmp(argv[i], "mapfile=", 8)) map_path = argv[i] + 8;
        else if (!strncmp(argv[i], "timefile=", 9)) time_path = argv[i] + 9;
        else if (!strncmp(argv[i], "interval=", 9)) {
            char *end;
            errno = 0;
            interval = strtoull(argv[i] + 9, &end, 0);
            if (errno || end == argv[i] + 9 || *end || !interval || argv[i][9] == '-') return -1;
        } else return -1;
    }
    if (!path || !*path) return -1;
    output = fopen(path, "wx");
    if (!output) return -1;
    if (map_path && !(mapping = fopen(map_path, "wx"))) return -1;
    if (time_path && !(timing = fopen(time_path, "wx"))) return -1;
    blocks = g_hash_table_new_full(block_hash, block_equal, g_free, NULL);
    qemu_plugin_register_vcpu_tb_trans_cb(id, translated);
    qemu_plugin_register_atexit_cb(id, finished, NULL);
    return 0;
}

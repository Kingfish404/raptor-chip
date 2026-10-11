/* NEMU architectural checkpoints for bounded RTL workload sampling.
 * ref_state.h is generated from the repository's canonical NPCState ABI.
 * No benchmark instructions, inputs, or reference answers are changed.
 */
#include <assert.h>
#include <dlfcn.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include "ref_state.h"

static NPCState state;
static void (*regcpy)(void *, bool);
static void (*memcpy_ref)(uint32_t, void *, size_t, bool);
static void (*execute)(uint64_t);
static uint64_t uart_reads;

static void count_fp(uint64_t *alu, uint64_t *load, uint64_t *store)
{
    uint32_t inst = *state.inst;
    unsigned opcode = inst & 0x7f;
    if ((inst & 3) == 3) {
        *alu += opcode == 0x53 || opcode == 0x43 || opcode == 0x47 || opcode == 0x4b || opcode == 0x4f;
        *load += opcode == 0x07;
        *store += opcode == 0x27;
    } else {
        unsigned funct3 = (inst >> 13) & 7, quadrant = inst & 3;
        *load += (quadrant == 0 || quadrant == 2) && (funct3 == 1 || (XLEN == 32 && funct3 == 3));
        *store += (quadrant == 0 || quadrant == 2) && (funct3 == 5 || (XLEN == 32 && funct3 == 7));
    }
}

static void step(void)
{
    execute(1);
    regcpy(&state, false);
    /* The shared reference omits devices. Model only the always-ready UART
     * status read needed during untimed startup. UART writes are discarded
     * by NEMU. No device substitution is permitted in measured windows. */
    uint32_t inst = *state.inst;
    if (state.skip && state.rvaddr == 0x10000005 && (inst & 0x707f) == 0x4003) {
        state.gpr[(inst >> 7) & 31] = 0x60;
        uart_reads++;
    }
    assert(*state.pc != 0);
}

static void save_memory(const char *directory)
{
    char path[8192];
    snprintf(path, sizeof(path), "%s/mem_pmem.bin", directory);
    FILE *data = fopen(path, "wb");
    assert(data);
    uint8_t block[65536];
    unsigned offsets[4096], count = 0;
    for (unsigned offset = 0; offset < 0x10000000; offset += sizeof(block)) {
        memcpy_ref(0x80000000u + offset, block, sizeof(block), false);
        bool nonzero = false;
        for (unsigned i = 0; i < sizeof(block); i++)
            nonzero |= block[i] != 0;
        if (!nonzero)
            continue;
        offsets[count++] = offset;
        assert(fwrite(block, 1, sizeof(block), data) == sizeof(block));
    }
    fclose(data);
    snprintf(path, sizeof(path), "%s/mem_pmem.bin.meta", directory);
    FILE *meta = fopen(path, "w");
    assert(meta);
    fprintf(meta, "size=0x10000000\nchunk_size=0x10000\nchunks=%u\n", count);
    for (unsigned i = 0; i < count; i++)
        fprintf(meta, "chunk=0x%x\n", offsets[i]);
    fclose(meta);
}

static void save_state(const char *directory)
{
    char path[8192];
    snprintf(path, sizeof(path), "%s/state.txt", directory);
    FILE *out = fopen(path, "w");
    assert(out);
    fprintf(out, "# Architectural NEMU state; cold RTL caches/predictor on restore.\n");
    fprintf(out, "xlen=%u\ncycle=0\ninstr=0\npc=0x%" PRIx64 "\npriv=%u\n",
            state.xlen, (uint64_t)*state.pc, (unsigned)*state.priv);
    for (unsigned i = 0; i < 32; i++) {
        fprintf(out, "gpr%u=0x%" PRIx64 "\n", i, (uint64_t)state.gpr[i]);
        fprintf(out, "fpr%u=0x%016" PRIx64 "\n", i, state.fpr[i]);
    }
#define CSR(key, field) fprintf(out, "csr_" key "=0x%" PRIx64 "\n", (uint64_t)*state.field)
    CSR("fcsr", fcsr);
    CSR("sstatus", sstatus); CSR("sie", sie____); CSR("stvec", stvec__);
    CSR("scounteren", scounte); CSR("mcounteren", mcounte);
    CSR("sscratch", sscratch); CSR("sepc", sepc___); CSR("scause", scause_);
    CSR("stval", stval__); CSR("sip", sip____); CSR("satp", satp___);
    CSR("mstatus", mstatus); CSR("medeleg", medeleg); CSR("mideleg", mideleg);
    CSR("mie", mie____); CSR("mtvec", mtvec__); CSR("menvcfg", menvcfg);
    CSR("mstatush", mstatush); CSR("mscratch", mscratch); CSR("mepc", mepc___);
    CSR("mcause", mcause_); CSR("mtval", mtval__); CSR("mip", mip____);
#undef CSR
    fprintf(out, "csr_mcycle=0\ncsr_mcycleh=0\ncsr_minstret=0\ncsr_minstreth=0\n"
                 "clint_mtime=0\nclint_mtimecmp=0xffffffffffffffff\nclint_msip=0\n"
                 "csr_stimecmp=0xffffffffffffffff\ncsr_stimecmph=0xffffffff\n");
    fclose(out);
    save_memory(directory);
}

int main(int argc, char **argv)
{
    /* reference image roi_start output warmup window offset... */
    /* --profile-roi reference image roi_start output roi_stop */
    bool profile = argc > 1 && strcmp(argv[1], "--profile-roi") == 0;
    if (profile) {
        argc--;
        argv++;
    }
    assert(profile ? argc == 6 : argc >= 8);
    void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!library) {
        fprintf(stderr, "%s\n", dlerror());
        return 1;
    }
    void (*init)(int);
    *(void **)(&init) = dlsym(library, "difftest_init");
    *(void **)(&regcpy) = dlsym(library, "difftest_regcpy");
    *(void **)(&memcpy_ref) = dlsym(library, "difftest_memcpy");
    *(void **)(&execute) = dlsym(library, "difftest_exec");
    assert(init && regcpy && memcpy_ref && execute);
    init(0);
    regcpy(&state, false);
    assert(state.xlen == XLEN && state.fpr && state.fcsr);
    FILE *image = fopen(argv[2], "rb");
    assert(image);
    uint8_t block[65536];
    size_t count;
    uint32_t address = 0x80000000;
    while ((count = fread(block, 1, sizeof(block), image))) {
        memcpy_ref(address, block, count, true);
        address += count;
    }
    fclose(image);
    *state.pc = 0x80000000;
    *state.priv = 3;
    uint64_t start_pc = strtoull(argv[3], NULL, 0), startup = 0;
    while (*state.pc != start_pc && startup < 1000000000ULL) {
        step();
        startup++;
    }
    assert(*state.pc == start_pc);
    if (profile) {
        uint64_t stop_pc = strtoull(argv[5], NULL, 0), instructions = 0;
        uint64_t alu = 0, load = 0, store = 0, uart_before = uart_reads;
        while (*state.pc != stop_pc && instructions < 1000000000ULL) {
            step();
            count_fp(&alu, &load, &store);
            instructions++;
        }
        assert(*state.pc == stop_pc && instructions && uart_reads == uart_before);
        char path[8192];
        snprintf(path, sizeof(path), "%s/roi.json", argv[4]);
        FILE *meta = fopen(path, "w");
        assert(meta);
        fprintf(meta, "{\"instructions\":%" PRIu64 ",\"startup_instructions\":%" PRIu64
                ",\"fp_alu\":%" PRIu64 ",\"fp_load\":%" PRIu64 ",\"fp_store\":%" PRIu64 "}\n",
                instructions, startup, alu, load, store);
        fclose(meta);
        return 0;
    }
    const uint64_t warmup = strtoull(argv[5], NULL, 0);
    const uint64_t window = strtoull(argv[6], NULL, 0);
    uint64_t cursor = 0;
    for (int sample = 7; sample < argc; sample++) {
        uint64_t offset = strtoull(argv[sample], NULL, 0);
        assert(offset >= cursor);
        if (offset > cursor)
            execute(offset - cursor);
        regcpy(&state, false);
        assert(*state.priv == 3 && *state.pc >= 0x80000000 && *state.pc < 0x88000000);
        char directory[4096];
        assert(snprintf(directory, sizeof(directory), "%s/sample-%d", argv[4], sample - 7) < (int)sizeof(directory));
        assert(mkdir(directory, 0777) == 0);
        save_state(directory);
        uint64_t uart_before = uart_reads;
        uint64_t fp_alu = 0, fp_load = 0, fp_store = 0;
        for (uint64_t i = 0; i < warmup + window; i++) {
            step();
            if (i < warmup)
                continue;
            count_fp(&fp_alu, &fp_load, &fp_store);
        }
        assert(uart_reads == uart_before);
        char path[8192];
        snprintf(path, sizeof(path), "%s/sample.json", directory);
        FILE *meta = fopen(path, "w");
        assert(meta);
        fprintf(meta, "{\"roi_offset_instructions\":%" PRIu64 ",\"startup_instructions\":%" PRIu64
                ",\"uart_status_reads_during_startup\":%" PRIu64 ",\"warmup\":%" PRIu64
                ",\"window\":%" PRIu64 ",\"fp_alu\":%" PRIu64 ",\"fp_load\":%" PRIu64
                ",\"fp_store\":%" PRIu64 "}\n", offset, startup, uart_before, warmup, window,
                fp_alu, fp_load, fp_store);
        fclose(meta);
        cursor = offset + warmup + window;
    }
    return 0;
}

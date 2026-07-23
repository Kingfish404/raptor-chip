#include "user.h"

static const char debug_help_text[] USER_DATA =
    "NAME\n    chip diagnostics - inspect RaptOS and the processor\n\n"
    "SYNOPSIS\n"
    "    meminfo\n    pmem_read ADDRESS [WORDS]\n"
    "    vmem_read ADDRESS [WORDS]\n    csr\n    mem_speed [ROUNDS]\n"
    "    tick CYCLES\n    smode\n    umode\n    priv\n\n"
    "DESCRIPTION\n"
    "    Read-only bring-up tools. Addresses accept decimal or 0x-prefixed hex.\n"
    "    pmem_read is restricted to RaptOS RAM; vmem_read walks the current\n"
    "    process page table without applying user R/W/X permissions.\n"
    "    tick enables preemptive timer interrupts every CYCLES cycles (0 off).\n"
    "    smode/umode switch this session between supervisor and user mode;\n"
    "    priv reports the current privilege level.\n";
static const char space[] USER_DATA = " ";
static const char newline[] USER_DATA = "\n";
static const char colon_space[] USER_DATA = ": ";
static const char cycles_text[] USER_DATA = "cycles ";
static const char instret_text[] USER_DATA = "instret ";
static const char bytes_text[] USER_DATA = "bytes ";
static const char ratio_text[] USER_DATA = " bytes/1000-cycles ";

static USER_TEXT void print_range(const char *name, uint32_t start, uint32_t end) {
    print(name);
    print(colon_space);
    print_hex(start);
    print("-");
    print_hex(end);
    print(newline);
}

static USER_TEXT int command_meminfo(void) {
    struct memory_layout layout;
    if (syscall3(SYS_DEBUG_INFO, (uint32_t)&layout, 0, 0)) return -1;
    print_range("ram", layout.ram_start, layout.ram_end);
    print_range("image", layout.ram_start, layout.image_end);
    print_range("kernel.text", layout.text_start, layout.text_end);
    print_range("user.rx", layout.user_start, layout.user_end);
    print_range("kernel.rodata", layout.rodata_start, layout.rodata_end);
    print_range("kernel.data", layout.data_start, layout.data_end);
    print_range("kernel.bss", layout.bss_start, layout.bss_end);
    print_range("user.stack", layout.user_stack_start, layout.user_stack_end);
    return 0;
}

static USER_TEXT int command_memory_read(int argc, char **argv, uint32_t address_space) {
    uint32_t address;
    uint32_t words = 1;
    if (argc < 2 || argc > 3 || parse_uint(argv[1], &address) ||
        (argc == 3 && parse_uint(argv[2], &words)) || !words || words > 16)
        return -1;
    for (uint32_t index = 0; index < words; index++) {
        struct debug_read_request request = { address + index * 4, address_space, 0 };
        if (syscall3(SYS_DEBUG_READ, (uint32_t)&request, 0, 0)) return -1;
        print_hex(request.address);
        print(colon_space);
        print_hex(request.value);
        print(newline);
    }
    return 0;
}

static USER_TEXT int command_csr(void) {
    struct performance_info info;
    if (syscall3(SYS_PERF_INFO, (uint32_t)&info, 0, 0)) return -1;
    print(cycles_text);
    print_hex(info.cycle_high);
    print(":");
    print_hex(info.cycle_low);
    print(newline);
    print(instret_text);
    print_hex(info.instret_high);
    print(":");
    print_hex(info.instret_low);
    print(newline);
    return 0;
}

static USER_TEXT int command_mem_speed(int argc, char **argv) {
    uint32_t rounds = 1024;
    if (argc > 2 || (argc == 2 && parse_uint(argv[1], &rounds)) || !rounds || rounds > 100000)
        return -1;
    volatile uint32_t buffer[64];
    struct performance_info before, after;
    for (uint32_t index = 0; index < 64; index++) buffer[index] = index;
    if (syscall3(SYS_PERF_INFO, (uint32_t)&before, 0, 0)) return -1;
    uint32_t checksum = 0;
    for (uint32_t round = 0; round < rounds; round++) {
        for (uint32_t index = 0; index < 64; index++) {
            uint32_t value = buffer[index];
            checksum += value;
            buffer[index] = value + 1;
        }
    }
    if (syscall3(SYS_PERF_INFO, (uint32_t)&after, 0, 0)) return -1;
    uint32_t cycles = after.cycle_low - before.cycle_low;
    uint32_t bytes = rounds * 64u * 8u;
    print(bytes_text);
    print_uint(bytes);
    print(space);
    print(cycles_text);
    print_uint(cycles);
    print(ratio_text);
    print_uint(cycles ? (bytes * 1000u) / cycles : 0);
    print(" checksum ");
    print_hex(checksum);
    print(newline);
    return 0;
}

static const char ticks_text[] USER_DATA = "ticks ";

static USER_TEXT int command_tick(int argc, char **argv) {
    uint32_t period;
    if (argc != 2 || parse_uint(argv[1], &period)) return -1;
    int previous = syscall3(SYS_TICK, period, 0, 0);
    if (previous < 0) return -1;
    print(ticks_text);
    print_uint((uint32_t)previous);
    print(newline);
    return 0;
}

static const char priv_smode_text[] USER_DATA = "S-mode\n";
static const char priv_umode_text[] USER_DATA = "U-mode\n";

static USER_TEXT int command_priv(uint32_t mode) {
    int result = syscall3(SYS_SMODE, mode, 0, 0);
    if (result < 0) return -1;
    print(result ? priv_smode_text : priv_umode_text);
    return 0;
}

int USER_TEXT debug_is_command(const char *command) {
    return text_equal(command, "meminfo") || text_equal(command, "pmem_read") ||
        text_equal(command, "vmem_read") || text_equal(command, "csr") ||
        text_equal(command, "mem_speed") || text_equal(command, "tick") ||
        text_equal(command, "smode") || text_equal(command, "umode") ||
        text_equal(command, "priv");
}

int USER_TEXT debug_show_help(const char *topic) {
    if (!debug_is_command(topic)) return -1;
    print(debug_help_text);
    return 0;
}

int USER_TEXT debug_command(int argc, char **argv) {
    if (text_equal(argv[0], "meminfo") && argc == 1) return command_meminfo();
    if (text_equal(argv[0], "pmem_read")) return command_memory_read(argc, argv, DEBUG_PHYSICAL);
    if (text_equal(argv[0], "vmem_read")) return command_memory_read(argc, argv, DEBUG_VIRTUAL);
    if (text_equal(argv[0], "csr") && argc == 1) return command_csr();
    if (text_equal(argv[0], "mem_speed")) return command_mem_speed(argc, argv);
    if (text_equal(argv[0], "tick")) return command_tick(argc, argv);
    if (text_equal(argv[0], "smode") && argc == 1) return command_priv(1);
    if (text_equal(argv[0], "umode") && argc == 1) return command_priv(0);
    if (text_equal(argv[0], "priv") && argc == 1) return command_priv(2);
    return -1;
}
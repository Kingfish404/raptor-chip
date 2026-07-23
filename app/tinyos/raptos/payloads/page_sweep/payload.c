/* Sweep a 512 KiB working set (128 distinct 4 KiB pages) through encoded
 * bit-30 pointer chains.  Every hop lands on a new page so the DTLB misses
 * constantly and Sv32 page-table walks interleave with D$ refills and
 * writebacks, like the Linux kernel touching many slabs.  Page bodies are
 * dirtied with mixed-width stores at rotating offsets and re-verified on
 * the next visit. */
#include <stdint.h>

#include "payload.h"

#define PAGE_TOTAL 128u
#define ROUNDS 150u
#define POINTER_MARKER 0x40000000u
#define POINTER_MASK (~POINTER_MARKER)
#define SWEEP_COOKIE 0x5eed5eedu

struct sweep_page {
    uint32_t next;       /* encoded pointer to next page */
    uint32_t generation;
    uint32_t checksum;   /* covers next + generation + noise */
    uint32_t noise_word;
    uint16_t noise_half;
    uint8_t noise_byte;
    uint8_t pad0;
    uint8_t body[4096u - 20u];
} __attribute__((aligned(4096)));

static struct sweep_page pages[PAGE_TOTAL] USER_BSS __attribute__((aligned(4096)));
static uint32_t random_state USER_BSS;
static uint32_t failure USER_BSS;

static const char start_text[] USER_DATA = "page_sweep: Sv32 stress start\n";
static const char pass_text[] USER_DATA = "page_sweep: PASS rounds=";
static const char fail_text[] USER_DATA = "page_sweep: FAIL ";
static const char round_text[] USER_DATA = " round=";
static const char expected_text[] USER_DATA = " expected=";
static const char actual_text[] USER_DATA = " actual=";
static const char newline[] USER_DATA = "\n";
static const char lost_marker[] USER_DATA = "page pointer lost bit 30";
static const char pointer_range[] USER_DATA = "page pointer out of range";
static const char chain_short[] USER_DATA = "pointer chain terminated early";
static const char checksum_mismatch[] USER_DATA = "page checksum mismatch";
static const char generation_mismatch[] USER_DATA = "page generation mismatch";
static const char body_mismatch[] USER_DATA = "page body mismatch";

static USER_TEXT void fail(const char *reason, uint32_t round, uint32_t expected,
                           uint32_t actual) {
    if (failure) return;
    failure = 1;
    print(fail_text);
    print(reason);
    print(round_text);
    print_hex(round);
    print(expected_text);
    print_hex(expected);
    print(actual_text);
    print_hex(actual);
    print(newline);
}

static USER_TEXT uint32_t random_next(void) {
    uint32_t value = random_state;
    value ^= value << 13;
    value ^= value >> 17;
    value ^= value << 5;
    random_state = value;
    return value;
}

static USER_TEXT uint32_t encode_pointer(struct sweep_page *page) {
    return (uint32_t)(uintptr_t)page | POINTER_MARKER;
}

static USER_TEXT uint32_t page_checksum(const struct sweep_page *page) {
    uint32_t value = page->next ^ SWEEP_COOKIE ^ (page->generation * 0x9e3779b9u) ^
        page->noise_word ^ ((uint32_t)page->noise_half << 8) ^ page->noise_byte;
    return (value << 9) | (value >> 23);
}

static USER_TEXT struct sweep_page *decode_pointer(uint32_t encoded, uint32_t round) {
    if (!(encoded & POINTER_MARKER)) {
        fail(lost_marker, round, encoded | POINTER_MARKER, encoded);
        return 0;
    }
    uint32_t address = encoded & POINTER_MASK;
    uint32_t first = (uint32_t)(uintptr_t)&pages[0];
    uint32_t limit = (uint32_t)(uintptr_t)&pages[PAGE_TOTAL];
    if (address < first || address >= limit || (address - first) % sizeof(pages[0])) {
        fail(pointer_range, round, first, address);
        return 0;
    }
    return (struct sweep_page *)(uintptr_t)address;
}

/* Relink all pages into a chain visiting them with the given odd stride so
 * each round takes a different page order (stride co-prime with 128). */
static USER_TEXT void relink_chain(uint32_t stride, uint32_t round) {
    for (uint32_t position = 0; position < PAGE_TOTAL; position++) {
        uint32_t index = (position * stride) % PAGE_TOTAL;
        uint32_t next_index = ((position + 1u) * stride) % PAGE_TOTAL;
        struct sweep_page *page = &pages[index];
        page->next = position + 1u < PAGE_TOTAL ? encode_pointer(&pages[next_index]) : 0u;
        page->generation = round;
        page->checksum = page_checksum(page);
    }
}

/* Walk the chain: verify last write, dirty page body with mixed widths. */
static USER_TEXT void walk_chain(uint32_t stride, uint32_t round) {
    struct sweep_page *page = &pages[0];
    uint32_t visited = 0;
    for (;;) {
        uint32_t expected = page_checksum(page);
        if (page->checksum != expected) {
            fail(checksum_mismatch, round, expected, page->checksum);
            return;
        }
        if (page->generation != round) {
            fail(generation_mismatch, round, round, page->generation);
            return;
        }
        visited++;

        /* Dirty a round-dependent offset inside the body with sb/sh/sw and
         * read it back through a differently sized load. */
        uint32_t value = random_next();
        uint32_t offset = (value >> 8) % (sizeof(page->body) - 8u);
        offset &= ~3u;
        uint8_t *slot = &page->body[offset];
        uint8_t byte = (uint8_t)value;
        uint16_t half = (uint16_t)(value >> 8);
        uint32_t word = value ^ 0xa5a55a5au;
        __asm__ volatile(
            "sw %2, 4(%3)\n"
            "sb %0, 0(%3)\n"
            "sh %1, 2(%3)\n"
            :
            : "r"(byte), "r"(half), "r"(word), "r"(slot)
            : "memory");
        uint32_t loaded;
        __asm__ volatile("lw %0, 4(%1)" : "=r"(loaded) : "r"(slot) : "memory");
        uint16_t loaded_half;
        __asm__ volatile("lhu %0, 2(%1)" : "=r"(loaded_half) : "r"(slot) : "memory");
        if (loaded != word || loaded_half != half || slot[0] != byte) {
            fail(body_mismatch, round, word, loaded);
            return;
        }

        /* Update noise fields covered by the checksum for the next visit. */
        page->noise_word = value;
        page->noise_half = half;
        page->noise_byte = byte;
        page->checksum = page_checksum(page);

        uint32_t next = page->next;
        if (!next) break;
        page = decode_pointer(next, round);
        if (!page) return;
    }
    if (visited != PAGE_TOTAL) fail(chain_short, round, PAGE_TOTAL, visited);
    (void)stride;
}

static USER_TEXT int run_page_sweep(int argc, char **argv) {
    (void)argc;
    (void)argv;
    print(start_text);
    random_state = 0xfeedbeefu;
    failure = 0;
    for (uint32_t round = 0; round < ROUNDS && !failure; round++) {
        uint32_t stride = ((random_next() >> 4) | 1u) % PAGE_TOTAL;
        if (!stride) stride = 1u;
        relink_chain(stride, round);
        walk_chain(stride, round);
    }
    if (failure) return -1;
    print(pass_text);
    print_hex(ROUNDS);
    print(newline);
    return 0;
}

RAPTOS_PAYLOAD(page_sweep_payload, "page_sweep",
               "sweep 128 pages via bit-30 chains to interleave PTW with refills",
               run_page_sweep);

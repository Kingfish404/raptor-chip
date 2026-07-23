/* Mimic the Linux SLUB cmpxchg fastpath: the freelist head is updated with
 * lr.w/sc.w retry loops while amoadd/amoswap/amoxor hit counters that share
 * cache lines with plain sb/sh/sw traffic.  Every freelist pointer carries
 * bit 30 (RAM window 0xc0000000-alias style marker) so a dropped bit is
 * detected immediately, matching the FPGA Linux panic signature. */
#include <stdint.h>

#include "payload.h"

#define NODE_COUNT 256u
#define ROUNDS 1000u
#define POINTER_MARKER 0x40000000u
#define POINTER_MASK (~POINTER_MARKER)
#define FREE_PATTERN 0x46524545u
#define USED_PATTERN 0x55534544u

struct amo_object {
    uint32_t next;      /* encoded freelist pointer */
    uint32_t state;
    uint32_t counter;   /* amoadd target */
    uint32_t swap_slot; /* amoswap target */
    uint8_t noise[16];  /* sb/sh traffic in the same line */
    uint32_t pad[10];
} __attribute__((aligned(64)));

static struct amo_object pool[NODE_COUNT] USER_BSS __attribute__((aligned(4096)));
static volatile uint32_t freelist_head USER_BSS;
static volatile uint32_t global_counter USER_BSS;
static uint32_t allocated[NODE_COUNT / 32u] USER_BSS;
static uint32_t allocated_count USER_BSS;
static uint32_t random_state USER_BSS;
static uint32_t failure USER_BSS;

static const char start_text[] USER_DATA = "amo_lrsc: Sv32 stress start\n";
static const char pass_text[] USER_DATA = "amo_lrsc: PASS rounds=";
static const char fail_text[] USER_DATA = "amo_lrsc: FAIL ";
static const char round_text[] USER_DATA = " round=";
static const char expected_text[] USER_DATA = " expected=";
static const char actual_text[] USER_DATA = " actual=";
static const char newline[] USER_DATA = "\n";
static const char lost_marker[] USER_DATA = "freelist pointer lost bit 30";
static const char pointer_range[] USER_DATA = "freelist pointer out of pool";
static const char state_mismatch[] USER_DATA = "object state mismatch";
static const char duplicate_alloc[] USER_DATA = "duplicate allocation";
static const char double_free[] USER_DATA = "double free";
static const char counter_mismatch[] USER_DATA = "amoadd counter mismatch";
static const char swap_mismatch[] USER_DATA = "amoswap value mismatch";
static const char noise_mismatch[] USER_DATA = "mixed-width noise mismatch";
static const char global_mismatch[] USER_DATA = "global amo counter mismatch";

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

static USER_TEXT uint32_t cmpxchg32(volatile uint32_t *ptr, uint32_t expected,
                                    uint32_t desired) {
    uint32_t observed, fail_flag;
    __asm__ volatile(
        "1: lr.w %0, (%2)\n"
        "   bne %0, %3, 2f\n"
        "   sc.w %1, %4, (%2)\n"
        "   bnez %1, 1b\n"
        "2:\n"
        : "=&r"(observed), "=&r"(fail_flag)
        : "r"(ptr), "r"(expected), "r"(desired)
        : "memory");
    return observed;
}

static USER_TEXT uint32_t amo_add(volatile uint32_t *ptr, uint32_t value) {
    uint32_t old;
    __asm__ volatile("amoadd.w %0, %2, (%1)" : "=r"(old) : "r"(ptr), "r"(value) : "memory");
    return old;
}

static USER_TEXT uint32_t amo_swap(volatile uint32_t *ptr, uint32_t value) {
    uint32_t old;
    __asm__ volatile("amoswap.w %0, %2, (%1)" : "=r"(old) : "r"(ptr), "r"(value) : "memory");
    return old;
}

static USER_TEXT uint32_t encode_pointer(struct amo_object *object) {
    return (uint32_t)(uintptr_t)object | POINTER_MARKER;
}

static USER_TEXT struct amo_object *decode_pointer(uint32_t encoded, uint32_t round) {
    if (!(encoded & POINTER_MARKER)) {
        fail(lost_marker, round, encoded | POINTER_MARKER, encoded);
        return 0;
    }
    uint32_t address = encoded & POINTER_MASK;
    uint32_t first = (uint32_t)(uintptr_t)&pool[0];
    uint32_t limit = (uint32_t)(uintptr_t)&pool[NODE_COUNT];
    if (address < first || address >= limit || (address - first) % sizeof(pool[0])) {
        fail(pointer_range, round, first, address);
        return 0;
    }
    return (struct amo_object *)(uintptr_t)address;
}

static USER_TEXT int is_allocated(uint32_t index) {
    return (allocated[index / 32u] >> (index % 32u)) & 1u;
}

static USER_TEXT void set_allocated(uint32_t index, int value) {
    uint32_t mask = 1u << (index % 32u);
    if (value)
        allocated[index / 32u] |= mask;
    else
        allocated[index / 32u] &= ~mask;
}

/* SLUB-style fastpath alloc: cmpxchg the freelist head. */
static USER_TEXT struct amo_object *allocate_object(uint32_t round) {
    for (;;) {
        uint32_t old = freelist_head;
        if (!old) return 0; /* empty */
        struct amo_object *object = decode_pointer(old, round);
        if (!object) return 0;
        uint32_t next = object->next;
        if (cmpxchg32(&freelist_head, old, next) != old) continue;
        uint32_t index = (uint32_t)(object - pool);
        if (object->state != FREE_PATTERN) {
            fail(state_mismatch, round, FREE_PATTERN, object->state);
            return 0;
        }
        if (is_allocated(index)) {
            fail(duplicate_alloc, round, 0u, index);
            return 0;
        }
        object->state = USED_PATTERN;
        set_allocated(index, 1);
        allocated_count++;
        return object;
    }
}

/* SLUB-style fastpath free: link object back with cmpxchg. */
static USER_TEXT void free_object(struct amo_object *object, uint32_t round) {
    uint32_t index = (uint32_t)(object - pool);
    if (!is_allocated(index)) {
        fail(double_free, round, 1u, index);
        return;
    }
    object->state = FREE_PATTERN;
    for (;;) {
        uint32_t old = freelist_head;
        object->next = old;
        if (cmpxchg32(&freelist_head, old, encode_pointer(object)) == old) break;
    }
    set_allocated(index, 0);
    allocated_count--;
}

/* Mix AMOs with plain mixed-width stores in the same cache line. */
static USER_TEXT void hammer_object(struct amo_object *object, uint32_t round) {
    uint32_t value = random_next();
    uint32_t before = object->counter;
    uint32_t observed = amo_add(&object->counter, 1u);
    if (observed != before) {
        fail(counter_mismatch, round, before, observed);
        return;
    }
    uint8_t byte = (uint8_t)value;
    uint16_t half = (uint16_t)(value >> 8);
    __asm__ volatile(
        "sb %0, 0(%2)\n"
        "sh %1, 2(%2)\n"
        :
        : "r"(byte), "r"(half), "r"(object->noise)
        : "memory");
    uint32_t swapped = amo_swap(&object->swap_slot, value);
    (void)swapped;
    uint32_t swap_back = amo_swap(&object->swap_slot, 0u);
    if (swap_back != value) {
        fail(swap_mismatch, round, value, swap_back);
        return;
    }
    uint16_t loaded_half;
    __asm__ volatile("lhu %0, 2(%1)" : "=r"(loaded_half) : "r"(object->noise) : "memory");
    if (object->noise[0] != byte || loaded_half != half)
        fail(noise_mismatch, round, ((uint32_t)half << 8) | byte,
             ((uint32_t)loaded_half << 8) | object->noise[0]);
    amo_add(&global_counter, 1u);
}

static USER_TEXT struct amo_object *choose_allocated(void) {
    uint32_t start = random_next() % NODE_COUNT;
    for (uint32_t offset = 0; offset < NODE_COUNT; offset++) {
        uint32_t index = (start + offset) % NODE_COUNT;
        if (is_allocated(index)) return &pool[index];
    }
    return 0;
}

static USER_TEXT void initialize_pool(void) {
    for (uint32_t index = 0; index < NODE_COUNT / 32u; index++) allocated[index] = 0;
    allocated_count = 0;
    random_state = 0x1234567u;
    failure = 0;
    global_counter = 0;
    for (uint32_t index = 0; index < NODE_COUNT; index++) {
        struct amo_object *object = &pool[index];
        object->next = index + 1u < NODE_COUNT ? encode_pointer(&pool[index + 1u]) : 0u;
        object->state = FREE_PATTERN;
        object->counter = 0;
        object->swap_slot = 0;
    }
    freelist_head = encode_pointer(&pool[0]);
}

static USER_TEXT int run_amo_lrsc(int argc, char **argv) {
    (void)argc;
    (void)argv;
    print(start_text);
    initialize_pool();
    uint32_t hammer_total = 0;
    for (uint32_t round = 0; round < ROUNDS && !failure; round++) {
        uint32_t action = random_next() % 4u;
        if (action != 0 && allocated_count < NODE_COUNT) {
            struct amo_object *object = allocate_object(round);
            if (object) {
                hammer_object(object, round);
                hammer_total++;
            }
        } else if (allocated_count) {
            struct amo_object *object = choose_allocated();
            if (object) {
                hammer_object(object, round);
                hammer_total++;
                free_object(object, round);
            }
        }
    }
    if (!failure && global_counter != hammer_total)
        fail(global_mismatch, ROUNDS, hammer_total, global_counter);
    if (failure) return -1;
    print(pass_text);
    print_hex(ROUNDS);
    print(newline);
    return 0;
}

RAPTOS_PAYLOAD(amo_lrsc_payload, "amo_lrsc",
               "SLUB-style lr/sc cmpxchg freelist with amoadd/amoswap traffic",
               run_amo_lrsc);

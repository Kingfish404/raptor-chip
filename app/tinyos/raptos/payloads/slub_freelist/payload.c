#include <stdint.h>

#include "payload.h"

#define NODE_COUNT 256u
#define ITERATIONS 1000u
#define POINTER_MARKER 0x40000000u
#define POINTER_MASK (~POINTER_MARKER)
#define FREELIST_COOKIE 0x6b8b4567u
#define FREE_PATTERN 0x46524545u
#define USED_PATTERN 0x55534544u

struct slab_object {
    uint32_t data[8];
    uint32_t next;
    uint32_t checksum;
    uint32_t state;
    uint32_t generation;
    uint8_t noise[16];
} __attribute__((aligned(64)));

static struct slab_object pool[NODE_COUNT] USER_BSS __attribute__((aligned(4096)));
static uint32_t allocated[NODE_COUNT / 32u] USER_BSS;
static uint32_t freelist_head USER_BSS;
static uint32_t allocated_count USER_BSS;
static uint32_t random_state USER_BSS;
static uint32_t failure USER_BSS;

static const char start_text[] USER_DATA = "slub_freelist: Sv32 stress start\n";
static const char pass_text[] USER_DATA = "slub_freelist: PASS iterations=";
static const char fail_text[] USER_DATA = "slub_freelist: FAIL ";
static const char iteration_text[] USER_DATA = " iteration=";
static const char expected_text[] USER_DATA = " expected=";
static const char actual_text[] USER_DATA = " actual=";
static const char newline[] USER_DATA = "\n";
static const char lost_marker[] USER_DATA = "freelist pointer lost bit 30";
static const char pointer_range[] USER_DATA = "freelist pointer out of pool";
static const char checksum_mismatch[] USER_DATA = "freelist checksum mismatch";
static const char state_mismatch[] USER_DATA = "freelist state mismatch";
static const char duplicate_alloc[] USER_DATA = "duplicate allocation";
static const char byte_mismatch[] USER_DATA = "byte store/load mismatch";
static const char half_mismatch[] USER_DATA = "half store/load mismatch";
static const char word_mismatch[] USER_DATA = "word store/load mismatch";
static const char double_free[] USER_DATA = "double free";
static const char bitmap_empty[] USER_DATA = "allocated bitmap empty";

static USER_TEXT void fail(const char *reason, uint32_t iteration, uint32_t expected,
                           uint32_t actual) {
    if (failure) return;
    failure = 1;
    print(fail_text);
    print(reason);
    print(iteration_text);
    print_hex(iteration);
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

static USER_TEXT uint32_t encode_pointer(struct slab_object *object) {
    return (uint32_t)(uintptr_t)object | POINTER_MARKER;
}

static USER_TEXT uint32_t object_index(const struct slab_object *object) {
    return (uint32_t)(object - pool);
}

static USER_TEXT uint32_t pointer_checksum(uint32_t next, uint32_t index,
                                           uint32_t generation) {
    uint32_t value = next ^ FREELIST_COOKIE ^ (index * 0x9e3779b9u) ^ generation;
    return (value << 7) | (value >> 25);
}

static USER_TEXT struct slab_object *decode_pointer(uint32_t encoded, uint32_t iteration) {
    if (!(encoded & POINTER_MARKER)) {
        fail(lost_marker, iteration, encoded | POINTER_MARKER, encoded);
        return 0;
    }

    uint32_t address = encoded & POINTER_MASK;
    uint32_t first = (uint32_t)(uintptr_t)&pool[0];
    uint32_t limit = (uint32_t)(uintptr_t)&pool[NODE_COUNT];
    if (address < first || address >= limit || (address - first) % sizeof(pool[0])) {
        fail(pointer_range, iteration, first, address);
        return 0;
    }
    return (struct slab_object *)(uintptr_t)address;
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

static USER_TEXT int write_noise(struct slab_object *object, uint32_t value) {
    uint8_t byte = (uint8_t)value;
    uint16_t half = (uint16_t)(value >> 8);
    uint32_t word = value ^ 0xa5a55a5au;
    __asm__ volatile(
        "sb %0, 0(%3)\n"
        "sh %1, 2(%3)\n"
        "sw %2, 4(%3)\n"
        :
        : "r"(byte), "r"(half), "r"(word), "r"(object->noise)
        : "memory");
    if (object->noise[0] != byte)
        fail(byte_mismatch, value, byte, object->noise[0]);
    uint16_t loaded_half;
    __asm__ volatile("lhu %0, 2(%1)" : "=r"(loaded_half) : "r"(object->noise) : "memory");
    if (loaded_half != half)
        fail(half_mismatch, value, half, loaded_half);
    uint32_t loaded_word;
    __asm__ volatile("lw %0, 4(%1)" : "=r"(loaded_word) : "r"(object->noise) : "memory");
    if (loaded_word != word)
        fail(word_mismatch, value, word, loaded_word);
    return failure ? -1 : 0;
}

static USER_TEXT struct slab_object *allocate_object(uint32_t iteration) {
    struct slab_object *object = decode_pointer(freelist_head, iteration);
    if (!object) return 0;
    uint32_t index = object_index(object);
    uint32_t next = object->next;
    uint32_t expected = pointer_checksum(next, index, object->generation);
    if (object->checksum != expected)
        fail(checksum_mismatch, iteration, expected, object->checksum);
    if (object->state != FREE_PATTERN)
        fail(state_mismatch, iteration, FREE_PATTERN, object->state);
    if (is_allocated(index))
        fail(duplicate_alloc, iteration, 0u, index);
    if (failure) return 0;

    freelist_head = next;
    object->state = USED_PATTERN;
    set_allocated(index, 1);
    allocated_count++;
    if (write_noise(object, random_next())) return 0;
    return object;
}

static USER_TEXT void free_object(struct slab_object *object, uint32_t iteration) {
    uint32_t index = object_index(object);
    if (!is_allocated(index)) {
        fail(double_free, iteration, 1u, index);
        return;
    }

    object->generation++;
    object->next = freelist_head;
    object->checksum = pointer_checksum(object->next, index, object->generation);
    object->state = FREE_PATTERN;
    freelist_head = encode_pointer(object);
    set_allocated(index, 0);
    allocated_count--;
}

static USER_TEXT struct slab_object *choose_allocated(void) {
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
    random_state = 1u;
    failure = 0;
    for (uint32_t index = 0; index < NODE_COUNT; index++) {
        struct slab_object *object = &pool[index];
        object->generation = index;
        object->next = index + 1u < NODE_COUNT ? encode_pointer(&pool[index + 1u]) : 0u;
        object->checksum = pointer_checksum(object->next, index, object->generation);
        object->state = FREE_PATTERN;
    }
    freelist_head = encode_pointer(&pool[0]);
}

static USER_TEXT int run_slub_freelist(int argc, char **argv) {
    (void)argc;
    (void)argv;
    print(start_text);
    initialize_pool();

    for (uint32_t iteration = 0; iteration < ITERATIONS && !failure; iteration++) {
        uint32_t choice = random_next();
        if (!allocated_count || (allocated_count < NODE_COUNT && (choice & 3u))) {
            if (!allocate_object(iteration)) break;
        } else {
            struct slab_object *object = choose_allocated();
            if (!object) fail(bitmap_empty, iteration, allocated_count, 0u);
            else free_object(object, iteration);
        }
    }

    if (failure) return -1;
    print(pass_text);
    print_hex(ITERATIONS);
    print(newline);
    return 0;
}

RAPTOS_PAYLOAD(slub_freelist_payload, "slub_freelist",
               "stress encoded freelists and mixed-width stores", run_slub_freelist);

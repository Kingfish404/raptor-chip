#include <stdint.h>

#include "payload.h"

#define CLASS_COUNT 5u
#define OBJECT_COUNT 512u
#define OBJECT_BYTES 128u
#define ROUNDS 1000u
#define MARKER 0x40000000u

struct object { uint8_t bytes[OBJECT_BYTES]; };
static struct object objects[OBJECT_COUNT] USER_BSS __attribute__((aligned(4096)));
static uint32_t next[OBJECT_COUNT] USER_BSS;
static uint32_t checksum[OBJECT_COUNT] USER_BSS;
static uint32_t heads[CLASS_COUNT] USER_BSS;
static uint8_t used[OBJECT_COUNT] USER_BSS;

static const char start_text[] USER_DATA = "slab_churn: Sv32 stress start\n";
static const char pass_text[] USER_DATA = "slab_churn: PASS rounds=";
static const char fail_text[] USER_DATA = "slab_churn: FAIL round=";
static const char expected_text[] USER_DATA = " expected=";
static const char actual_text[] USER_DATA = " actual=";
static const char newline[] USER_DATA = "\n";

static USER_TEXT uint32_t encode(uint32_t index) {
    return (uint32_t)(uintptr_t)&objects[index] | MARKER;
}
static USER_TEXT uint32_t index_of(uint32_t pointer) {
    return ((pointer & ~MARKER) - (uint32_t)(uintptr_t)&objects[0]) / sizeof(objects[0]);
}
static USER_TEXT uint32_t make_checksum(uint32_t value, uint32_t index) {
    return (value << 11 | value >> 21) ^ index ^ 0x6b8b4567u;
}
static USER_TEXT int report(uint32_t round, uint32_t wanted, uint32_t actual) {
    print(fail_text); print_hex(round); print(expected_text); print_hex(wanted);
    print(actual_text); print_hex(actual); print(newline); return -1;
}

static USER_TEXT int run_slab_churn(int argc, char **argv) {
    (void)argc; (void)argv;
    print(start_text);
    for (uint32_t cls = 0; cls < CLASS_COUNT; cls++) heads[cls] = 0;
    for (uint32_t index = 0; index < OBJECT_COUNT; index++) {
        uint32_t cls = index % CLASS_COUNT;
        next[index] = heads[cls];
        checksum[index] = make_checksum(next[index], index);
        heads[cls] = encode(index);
        used[index] = 0;
    }

    uint32_t state = 0xdeadbeefu;
    for (uint32_t round = 0; round < ROUNDS; round++) {
        state = state * 1103515245u + 12345u;
        uint32_t cls = (state >> 8) % CLASS_COUNT;
        uint32_t head = heads[cls];
        if (!head || !(head & MARKER)) return report(round, head | MARKER, head);
        uint32_t index = index_of(head);
        if (index >= OBJECT_COUNT || used[index]) return report(round, 0u, index);
        if (checksum[index] != make_checksum(next[index], index))
            return report(round, make_checksum(next[index], index), checksum[index]);
        heads[cls] = next[index];
        used[index] = 1;

        uint32_t size = 8u << cls;
        uint32_t pattern = state ^ head;
        volatile uint8_t *bytes = objects[index].bytes;
        for (uint32_t offset = 0; offset < size; offset++) bytes[offset] = (uint8_t)(pattern + offset);
        for (uint32_t offset = 0; offset < size; offset++)
            if (bytes[offset] != (uint8_t)(pattern + offset))
                return report(round, (uint8_t)(pattern + offset), bytes[offset]);

        next[index] = heads[cls];
        checksum[index] = make_checksum(next[index], index);
        used[index] = 0;
        heads[cls] = encode(index);
    }
    print(pass_text); print_hex(ROUNDS); print(newline); return 0;
}

RAPTOS_PAYLOAD(slab_churn_payload, "slab_churn",
               "churn size-class freelists with byte-filled objects", run_slab_churn);
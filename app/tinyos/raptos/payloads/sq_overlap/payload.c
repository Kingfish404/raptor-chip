#include <stdint.h>

#include "payload.h"

#define SLOT_COUNT 1024u
#define ROUNDS 1000u

static uint32_t words[SLOT_COUNT] USER_BSS __attribute__((aligned(4096)));
static uint32_t shadow[SLOT_COUNT] USER_BSS;

static const char start_text[] USER_DATA = "sq_overlap: Sv32 stress start\n";
static const char pass_text[] USER_DATA = "sq_overlap: PASS rounds=";
static const char fail_text[] USER_DATA = "sq_overlap: FAIL round=";
static const char index_text[] USER_DATA = " index=";
static const char expected_text[] USER_DATA = " expected=";
static const char actual_text[] USER_DATA = " actual=";
static const char newline[] USER_DATA = "\n";

static USER_TEXT int fail(uint32_t round, uint32_t index, uint32_t wanted, uint32_t actual) {
    print(fail_text); print_hex(round); print(index_text); print_hex(index);
    print(expected_text); print_hex(wanted); print(actual_text); print_hex(actual); print(newline);
    return -1;
}

static USER_TEXT int run_sq_overlap(int argc, char **argv) {
    (void)argc; (void)argv;
    print(start_text);
    for (uint32_t index = 0; index < SLOT_COUNT; index++)
        words[index] = shadow[index] = 0xc0000000u ^ (index * 0x9e3779b9u);

    uint32_t state = 0x1234567bu;
    for (uint32_t round = 0; round < ROUNDS; round++) {
        state ^= state << 13; state ^= state >> 17; state ^= state << 5;
        uint32_t index = state & (SLOT_COUNT - 1u);
        uint32_t neighbor = (index + 257u) & (SLOT_COUNT - 1u);
        uint32_t value = state ^ 0x40000000u ^ round;
        volatile uint8_t *bytes = (volatile uint8_t *)&words[index];
        volatile uint16_t *halves = (volatile uint16_t *)&words[index];

        switch (round & 3u) {
        case 0:
            __asm__ volatile("sw %0, 0(%1)\nlw %0, 0(%1)" : "+r"(value) : "r"(&words[index]) : "memory");
            shadow[index] = state ^ 0x40000000u ^ round;
            break;
        case 1:
            bytes[1] = (uint8_t)(value >> 8);
            shadow[index] = (shadow[index] & 0xffff00ffu) | (value & 0x0000ff00u);
            break;
        case 2:
            halves[1] = (uint16_t)(value >> 16);
            shadow[index] = (shadow[index] & 0x0000ffffu) | (value & 0xffff0000u);
            break;
        default:
            bytes[0] = (uint8_t)value;
            halves[1] = (uint16_t)(value >> 16);
            bytes[1] = (uint8_t)(value >> 8);
            shadow[index] = value;
            break;
        }

        uint32_t actual = words[index];
        if (actual != shadow[index]) return fail(round, index, shadow[index], actual);
        actual = words[neighbor];
        if (actual != shadow[neighbor]) return fail(round, neighbor, shadow[neighbor], actual);
    }
    print(pass_text); print_hex(ROUNDS); print(newline);
    return 0;
}

RAPTOS_PAYLOAD(sq_overlap_payload, "sq_overlap",
               "stress overlapping sb/sh/sw forwarding and drains", run_sq_overlap);
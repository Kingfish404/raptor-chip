#include <stdint.h>

#include "payload.h"

#define SET_STRIDE 1024u
#define CONFLICT_LINES 8u
#define WORDS_PER_LINE 16u
#define ROUNDS 20000u

static uint8_t arena[SET_STRIDE * CONFLICT_LINES + 64u] USER_BSS __attribute__((aligned(4096)));
static uint32_t expected[CONFLICT_LINES][WORDS_PER_LINE] USER_BSS;

static const char start_text[] USER_DATA = "cache_refill_conflict: Sv32 stress start\n";
static const char pass_text[] USER_DATA = "cache_refill_conflict: PASS rounds=";
static const char fail_text[] USER_DATA = "cache_refill_conflict: FAIL round=";
static const char line_text[] USER_DATA = " line=";
static const char word_text[] USER_DATA = " word=";
static const char expected_text[] USER_DATA = " expected=";
static const char actual_text[] USER_DATA = " actual=";
static const char newline[] USER_DATA = "\n";

static USER_TEXT volatile uint32_t *line_words(uint32_t line) {
    return (volatile uint32_t *)(arena + line * SET_STRIDE);
}

static USER_TEXT int report_failure(uint32_t round, uint32_t line, uint32_t word,
                                    uint32_t wanted, uint32_t actual) {
    print(fail_text); print_hex(round);
    print(line_text); print_hex(line);
    print(word_text); print_hex(word);
    print(expected_text); print_hex(wanted);
    print(actual_text); print_hex(actual); print(newline);
    return -1;
}

static USER_TEXT int run_cache_refill_conflict(int argc, char **argv) {
    (void)argc; (void)argv;
    print(start_text);
    for (uint32_t line = 0; line < CONFLICT_LINES; line++)
        for (uint32_t word = 0; word < WORDS_PER_LINE; word++) {
            uint32_t value = 0xc0000000u ^ (line << 20) ^ (word * 0x01010101u);
            expected[line][word] = value;
            line_words(line)[word] = value;
        }

    uint32_t state = 0x31415927u;
    for (uint32_t round = 0; round < ROUNDS; round++) {
        state = state * 1664525u + 1013904223u;
        uint32_t line = state & (CONFLICT_LINES - 1u);
        uint32_t word = (state >> 8) & (WORDS_PER_LINE - 1u);
        volatile uint32_t *target = line_words(line);
        uint32_t value = expected[line][word] ^ (0x40000001u + round);

        if (round & 1u) {
            volatile uint8_t *bytes = (volatile uint8_t *)&target[word];
            bytes[0] = (uint8_t)value;
            bytes[1] = (uint8_t)(value >> 8);
            bytes[2] = (uint8_t)(value >> 16);
            bytes[3] = (uint8_t)(value >> 24);
        } else {
            volatile uint16_t *halves = (volatile uint16_t *)&target[word];
            halves[0] = (uint16_t)value;
            halves[1] = (uint16_t)(value >> 16);
        }
        expected[line][word] = value;

        for (uint32_t evict = 0; evict < CONFLICT_LINES; evict++) {
            uint32_t probe_word = (word + evict) & (WORDS_PER_LINE - 1u);
            uint32_t actual = line_words(evict)[probe_word];
            uint32_t wanted = expected[evict][probe_word];
            if (actual != wanted)
                return report_failure(round, evict, probe_word, wanted, actual);
        }
    }
    print(pass_text); print_hex(ROUNDS); print(newline);
    return 0;
}

RAPTOS_PAYLOAD(cache_refill_conflict_payload, "cache_refill_conflict",
               "thrash one L1D set during mixed-width updates", run_cache_refill_conflict);
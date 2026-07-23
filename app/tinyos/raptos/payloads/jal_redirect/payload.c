#include <stdint.h>

#include "payload.h"

#define ROUNDS 4096u

static const char start_text[] USER_DATA = "jal_redirect: direct JAL stress start\n";
static const char pass_text[] USER_DATA = "jal_redirect: PASS rounds=";
static const char fail_text[] USER_DATA = "jal_redirect: FAIL round=";
static const char expected_text[] USER_DATA = " expected=";
static const char actual_text[] USER_DATA = " actual=";
static const char newline[] USER_DATA = "\n";

static uint32_t USER_TEXT __attribute__((naked)) probe_negative_jal(
    uint32_t value __attribute__((unused))) {
    __asm__ volatile(
        ".option push\n"
        ".option norvc\n"
        "li t1, 0\n"
        "beqz t1, 2f\n"
        "1:\n"
        "addi a0, a0, 1\n"
        "ret\n"
        ".rept 48\n"
        "nop\n"
        ".endr\n"
        "2:\n"
        "mv t0, ra\n"
        "li t6, 0x800004a0\n"
        "jal ra, 1b\n"
        "mv ra, t0\n"
        "ret\n"
        ".option pop\n");
}

static USER_TEXT int run_jal_redirect(int argc, char **argv) {
    (void)argc;
    (void)argv;
    print(start_text);

    uint32_t value = 0x13579bdfu;
    for (uint32_t round = 0; round < ROUNDS; round++) {
        uint32_t expected = value + 1u;
        uint32_t actual = probe_negative_jal(value);
        if (actual != expected) {
            print(fail_text); print_hex(round);
            print(expected_text); print_hex(expected);
            print(actual_text); print_hex(actual); print(newline);
            return -1;
        }
        value = actual ^ (round * 0x9e3779b9u);
    }

    print(pass_text); print_hex(ROUNDS); print(newline);
    return 0;
}

RAPTOS_PAYLOAD(jal_redirect_payload, "jal_redirect",
               "stress negative direct JAL targets with a high x31 sentinel",
               run_jal_redirect);
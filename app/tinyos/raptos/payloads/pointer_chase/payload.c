#include <stdint.h>

#include "payload.h"

#define NODE_COUNT 4096u
#define ROUNDS 500000u
#define MARKER 0x40000000u

struct node { uint32_t next; uint32_t inverse; uint32_t salt; uint32_t check; };
static struct node nodes[NODE_COUNT] USER_BSS __attribute__((aligned(4096)));

static const char start_text[] USER_DATA = "pointer_chase: Sv32 stress start\n";
static const char pass_text[] USER_DATA = "pointer_chase: PASS rounds=";
static const char fail_text[] USER_DATA = "pointer_chase: FAIL round=";
static const char expected_text[] USER_DATA = " expected=";
static const char actual_text[] USER_DATA = " actual=";
static const char newline[] USER_DATA = "\n";

static USER_TEXT uint32_t encode(struct node *node) { return (uint32_t)(uintptr_t)node | MARKER; }
static USER_TEXT struct node *decode(uint32_t value) {
    return (struct node *)(uintptr_t)(value & ~MARKER);
}

static USER_TEXT int run_pointer_chase(int argc, char **argv) {
    (void)argc; (void)argv;
    print(start_text);
    for (uint32_t index = 0; index < NODE_COUNT; index++) {
        uint32_t next = (index * 109u + 89u) & (NODE_COUNT - 1u);
        nodes[index].next = encode(&nodes[next]);
        nodes[index].inverse = ~nodes[index].next;
        nodes[index].salt = index ^ 0xa5a55a5au;
        nodes[index].check = nodes[index].next ^ nodes[index].inverse ^ nodes[index].salt;
    }

    struct node *node = &nodes[0];
    for (uint32_t round = 0; round < ROUNDS; round++) {
        uint32_t value = node->next;
        uint32_t wanted = encode(decode(value));
        if (!(value & MARKER) || value != wanted || node->inverse != ~value ||
            node->check != (value ^ node->inverse ^ node->salt)) {
            print(fail_text); print_hex(round); print(expected_text); print_hex(wanted);
            print(actual_text); print_hex(value); print(newline);
            return -1;
        }
        node = decode(value);
    }
    print(pass_text); print_hex(ROUNDS); print(newline);
    return 0;
}

RAPTOS_PAYLOAD(pointer_chase_payload, "pointer_chase",
               "preserve bit-30 pointers through long load/writeback chains", run_pointer_chase);
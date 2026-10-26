#define _POSIX_C_SOURCE 200112L
#include "profile.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

/* One node per 16-byte cache line; random order prevents streaming locality. */
struct node {
    struct node *volatile next;
    uint64_t padding;
};

static uint32_t random_state = 42;
static uint32_t random_u32(void)
{
    random_state ^= random_state << 13;
    random_state ^= random_state >> 17;
    random_state ^= random_state << 5;
    return random_state;
}

static struct node *chase(struct node *p, size_t steps)
{
    for (size_t i = 0; i < steps / 8; i++) {
        p = p->next; p = p->next; p = p->next; p = p->next;
        p = p->next; p = p->next; p = p->next; p = p->next;
    }
    return p;
}

int main(void)
{
    const size_t sizes[] = {1024, 8192, 16384, 32768, 65536, 262144, 1048576};
    const size_t steps = 4194304;
    for (size_t s = 0; s < sizeof(sizes) / sizeof(sizes[0]); s++) {
        const size_t n = sizes[s] / sizeof(struct node);
        struct node *nodes;
        if (posix_memalign((void **)&nodes, 4096, sizes[s]))
            return 2;
        size_t *order = malloc(n * sizeof(*order));
        if (!order)
            return 2;
        for (size_t i = 0; i < n; i++)
            order[i] = i;
        for (size_t i = n - 1; i; i--) {
            size_t j = random_u32() % (i + 1);
            size_t temp = order[i]; order[i] = order[j]; order[j] = temp;
        }
        for (size_t i = 0; i < n; i++)
            nodes[order[i]].next = &nodes[order[(i + 1) % n]];
        free(order);
        char name[64];
        snprintf(name, sizeof(name), "chase_%zu_bytes", sizes[s]);
        profile_init(name);
        struct node *start = &nodes[0];
        struct node *p = chase(start, n * 4);
        profile_begin();
        p = chase(p, steps);
        profile_end();
        profile_report();
        printf("MEMORY_VERIFY bytes=%zu steps=%zu correct=%d\n", sizes[s], steps, p == start);
        if (p != start)
            return 1;
        free(nodes);
    }
    volatile uint64_t *stores = calloc(128, sizeof(*stores));
    if (!stores)
        return 2;
    profile_init("store_1024_bytes");
    for (size_t i = 0; i < 128; i++)
        stores[i] = i;
    profile_begin();
    for (size_t i = 0; i < steps; i += 8) {
        size_t j = i & 127;
        stores[j] = i; stores[j + 1] = i; stores[j + 2] = i; stores[j + 3] = i;
        stores[j + 4] = i; stores[j + 5] = i; stores[j + 6] = i; stores[j + 7] = i;
    }
    __asm__ volatile("fence rw,rw" ::: "memory");
    profile_end();
    profile_report();
    int correct = 1;
    for (size_t j = 0; j < 128; j++)
        if (stores[j] != steps - 128 + (j & ~(size_t)7))
            correct = 0;
    printf("MEMORY_VERIFY store_steps=%zu correct=%d\n", steps, correct);
    free((void *)stores);
    return correct ? 0 : 1;
}

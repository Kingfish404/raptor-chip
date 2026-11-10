#include <stdint.h>

/* Checks that startup copied initialized data and cleared BSS before main. */
static volatile uint32_t initialized = 0x1234abcd;
static volatile uint32_t cleared;

int main(void) { return initialized != 0x1234abcd || cleared != 0; }

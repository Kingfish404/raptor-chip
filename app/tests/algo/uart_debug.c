/* uart_debug.c: minimal test — heavy computation then printf */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

static uint8_t sieve[1001];

int main(void) {
    /* Sieve of Eratosthenes */
    for (int i = 0; i <= 1000; i++) sieve[i] = 1;
    sieve[0] = sieve[1] = 0;
    for (int i = 2; i * i <= 1000; i++)
        if (sieve[i])
            for (int j = i * i; j <= 1000; j += i)
                sieve[j] = 0;
    int count = 0;
    for (int i = 0; i <= 1000; i++) count += sieve[i];

    printf("primes: %d\n", count);
    return (count == 168) ? EXIT_SUCCESS : EXIT_FAILURE;
}

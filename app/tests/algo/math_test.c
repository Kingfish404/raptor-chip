/* math_test.c: Integer math — fibonacci, prime sieve, GCD, matrix multiply */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

#define CHECK(cond, msg) do { \
    if (!(cond)) { printf("FAIL: %s (line %d)\n", msg, __LINE__); fail++; } \
    else { pass++; } \
} while (0)

static int pass = 0, fail = 0;

/* Iterative fibonacci */
static long fib(int n) {
    long a = 0, b = 1;
    for (int i = 0; i < n; i++) {
        long t = a + b;
        a = b;
        b = t;
    }
    return a;
}

/* GCD (Euclid) */
static long gcd(long a, long b) {
    while (b) { long t = b; b = a % b; a = t; }
    return a;
}

/* Sieve of Eratosthenes — count primes up to N */
#define SIEVE_MAX 1000
static uint8_t sieve[SIEVE_MAX + 1];
static int count_primes(int n) {
    for (int i = 0; i <= n; i++) sieve[i] = 1;
    sieve[0] = sieve[1] = 0;
    for (int i = 2; i * i <= n; i++)
        if (sieve[i])
            for (int j = i * i; j <= n; j += i)
                sieve[j] = 0;
    int count = 0;
    for (int i = 0; i <= n; i++) count += sieve[i];
    return count;
}

/* 4x4 matrix multiply (int) */
static void matmul4(int c[4][4], const int a[4][4], const int b[4][4]) {
    for (int i = 0; i < 4; i++)
        for (int j = 0; j < 4; j++) {
            c[i][j] = 0;
            for (int k = 0; k < 4; k++)
                c[i][j] += a[i][k] * b[k][j];
        }
}

int main(void) {
    /* Fibonacci */
    CHECK(fib(0) == 0, "fib(0) = 0");
    CHECK(fib(1) == 1, "fib(1) = 1");
    CHECK(fib(10) == 55, "fib(10) = 55");
    CHECK(fib(20) == 6765, "fib(20) = 6765");
    CHECK(fib(30) == 832040, "fib(30) = 832040");

    /* GCD */
    CHECK(gcd(12, 8) == 4, "gcd(12,8) = 4");
    CHECK(gcd(100, 75) == 25, "gcd(100,75) = 25");
    CHECK(gcd(17, 13) == 1, "gcd(17,13) = 1 (coprime)");
    CHECK(gcd(0, 5) == 5, "gcd(0,5) = 5");

    /* Primes */
    CHECK(count_primes(10) == 4, "primes <= 10: 4");
    CHECK(count_primes(100) == 25, "primes <= 100: 25");
    CHECK(count_primes(1000) == 168, "primes <= 1000: 168");

    /* Matrix multiply: identity */
    {
        int I[4][4] = {{1,0,0,0},{0,1,0,0},{0,0,1,0},{0,0,0,1}};
        int A[4][4] = {{1,2,3,4},{5,6,7,8},{9,10,11,12},{13,14,15,16}};
        int C[4][4];
        matmul4(C, A, I);
        int ok = 1;
        for (int i = 0; i < 4 && ok; i++)
            for (int j = 0; j < 4 && ok; j++)
                if (C[i][j] != A[i][j]) ok = 0;
        CHECK(ok, "matmul: A * I = A");
    }

    /* Matrix multiply: known result */
    {
        int A[4][4] = {{1,2,0,0},{3,4,0,0},{0,0,1,0},{0,0,0,1}};
        int B[4][4] = {{5,6,0,0},{7,8,0,0},{0,0,1,0},{0,0,0,1}};
        int C[4][4];
        matmul4(C, A, B);
        /* C[0][0]=1*5+2*7=19, C[0][1]=1*6+2*8=22
         * C[1][0]=3*5+4*7=43, C[1][1]=3*6+4*8=50 */
        CHECK(C[0][0] == 19, "matmul: [0][0]=19");
        CHECK(C[0][1] == 22, "matmul: [0][1]=22");
        CHECK(C[1][0] == 43, "matmul: [1][0]=43");
        CHECK(C[1][1] == 50, "matmul: [1][1]=50");
        CHECK(C[2][2] == 1 && C[3][3] == 1, "matmul: identity block preserved");
    }

    printf("math_test: %d passed, %d failed\n", pass, fail);
    return fail ? EXIT_FAILURE : EXIT_SUCCESS;
}

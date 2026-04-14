/* sorting.c: Test sorting algorithms — exercises branches, memory access, comparison */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

#define CHECK(cond, msg) do { \
    if (!(cond)) { printf("FAIL: %s (line %d)\n", msg, __LINE__); fail++; } \
    else { pass++; } \
} while (0)

static int pass = 0, fail = 0;

static int is_sorted(const int *a, int n) {
    for (int i = 1; i < n; i++)
        if (a[i] < a[i - 1]) return 0;
    return 1;
}

static void bubble_sort(int *a, int n) {
    for (int i = 0; i < n - 1; i++)
        for (int j = 0; j < n - 1 - i; j++)
            if (a[j] > a[j + 1]) {
                int t = a[j]; a[j] = a[j + 1]; a[j + 1] = t;
            }
}

static void selection_sort(int *a, int n) {
    for (int i = 0; i < n - 1; i++) {
        int min_idx = i;
        for (int j = i + 1; j < n; j++)
            if (a[j] < a[min_idx]) min_idx = j;
        int t = a[i]; a[i] = a[min_idx]; a[min_idx] = t;
    }
}

static void quick_sort(int *a, int lo, int hi) {
    if (lo >= hi) return;
    int pivot = a[(lo + hi) / 2];
    int i = lo, j = hi;
    while (i <= j) {
        while (a[i] < pivot) i++;
        while (a[j] > pivot) j--;
        if (i <= j) {
            int t = a[i]; a[i] = a[j]; a[j] = t;
            i++; j--;
        }
    }
    quick_sort(a, lo, j);
    quick_sort(a, i, hi);
}

#define N 64
static int data[N];

static void fill_reverse(int *a, int n) {
    for (int i = 0; i < n; i++) a[i] = n - i;
}

static uint32_t lfsr = 0xDEAD;
static void fill_random(int *a, int n) {
    for (int i = 0; i < n; i++) {
        lfsr = (lfsr >> 1) ^ (-(lfsr & 1u) & 0xD0000001u);
        a[i] = (int)(lfsr % 10000);
    }
}

int main(void) {
    /* Bubble sort */
    fill_reverse(data, N);
    bubble_sort(data, N);
    CHECK(is_sorted(data, N), "bubble sort: reverse input");

    fill_random(data, N);
    bubble_sort(data, N);
    CHECK(is_sorted(data, N), "bubble sort: random input");

    /* Selection sort */
    fill_reverse(data, N);
    selection_sort(data, N);
    CHECK(is_sorted(data, N), "selection sort: reverse input");

    fill_random(data, N);
    selection_sort(data, N);
    CHECK(is_sorted(data, N), "selection sort: random input");

    /* Quick sort */
    fill_reverse(data, N);
    quick_sort(data, 0, N - 1);
    CHECK(is_sorted(data, N), "quick sort: reverse input");

    fill_random(data, N);
    quick_sort(data, 0, N - 1);
    CHECK(is_sorted(data, N), "quick sort: random input");

    /* Already sorted */
    for (int i = 0; i < N; i++) data[i] = i;
    quick_sort(data, 0, N - 1);
    CHECK(is_sorted(data, N), "quick sort: already sorted");

    /* All same values */
    for (int i = 0; i < N; i++) data[i] = 42;
    bubble_sort(data, N);
    CHECK(is_sorted(data, N) && data[0] == 42, "bubble sort: all equal");

    /* Single element */
    data[0] = 99;
    quick_sort(data, 0, 0);
    CHECK(data[0] == 99, "quick sort: single element");

    printf("sorting: %d passed, %d failed\n", pass, fail);
    return fail ? EXIT_FAILURE : EXIT_SUCCESS;
}

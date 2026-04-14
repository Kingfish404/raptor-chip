/* string_ops.c: String operations — exercises byte memory access patterns */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

#define CHECK(cond, msg) do { \
    if (!(cond)) { printf("FAIL: %s (line %d)\n", msg, __LINE__); fail++; } \
    else { pass++; } \
} while (0)

static int pass = 0, fail = 0;

/* Custom implementations to test more thoroughly */
static size_t my_strlen(const char *s) {
    size_t n = 0;
    while (s[n]) n++;
    return n;
}

static int my_strcmp(const char *a, const char *b) {
    while (*a && *a == *b) { a++; b++; }
    return (unsigned char)*a - (unsigned char)*b;
}

static char *my_strcpy(char *dst, const char *src) {
    char *ret = dst;
    while ((*dst++ = *src++));
    return ret;
}

static void *my_memset(void *s, int c, size_t n) {
    uint8_t *p = (uint8_t *)s;
    while (n--) *p++ = (uint8_t)c;
    return s;
}

static void *my_memcpy(void *dst, const void *src, size_t n) {
    uint8_t *d = (uint8_t *)dst;
    const uint8_t *s = (const uint8_t *)src;
    while (n--) *d++ = *s++;
    return dst;
}

/* Simple string reversal */
static void reverse(char *s, size_t len) {
    for (size_t i = 0; i < len / 2; i++) {
        char t = s[i];
        s[i] = s[len - 1 - i];
        s[len - 1 - i] = t;
    }
}

/* itoa (base 10, signed) */
static void my_itoa(int val, char *buf) {
    if (val == 0) { buf[0] = '0'; buf[1] = '\0'; return; }
    int neg = (val < 0);
    unsigned int uv = neg ? (unsigned int)(-(long)val) : (unsigned int)val;
    int i = 0;
    while (uv) { buf[i++] = '0' + (uv % 10); uv /= 10; }
    if (neg) buf[i++] = '-';
    buf[i] = '\0';
    reverse(buf, (size_t)i);
}

int main(void) {
    /* strlen */
    CHECK(my_strlen("") == 0, "strlen empty");
    CHECK(my_strlen("hello") == 5, "strlen hello");
    CHECK(my_strlen("RISC-V") == 6, "strlen RISC-V");

    /* strcmp */
    CHECK(my_strcmp("abc", "abc") == 0, "strcmp equal");
    CHECK(my_strcmp("abc", "abd") < 0, "strcmp less");
    CHECK(my_strcmp("abd", "abc") > 0, "strcmp greater");
    CHECK(my_strcmp("", "") == 0, "strcmp empty");
    CHECK(my_strcmp("a", "") > 0, "strcmp 'a' > ''");

    /* strcpy */
    {
        char buf[32];
        my_strcpy(buf, "Hello, World!");
        CHECK(my_strcmp(buf, "Hello, World!") == 0, "strcpy basic");
    }
    {
        char buf[4];
        my_strcpy(buf, "");
        CHECK(buf[0] == '\0', "strcpy empty string");
    }

    /* memset */
    {
        char buf[16];
        my_memset(buf, 'X', 16);
        int ok = 1;
        for (int i = 0; i < 16; i++) if (buf[i] != 'X') ok = 0;
        CHECK(ok, "memset fill X");
    }

    /* memcpy */
    {
        char src[] = "RISC-V Rocks!";
        char dst[32];
        my_memcpy(dst, src, sizeof(src));
        CHECK(my_strcmp(dst, src) == 0, "memcpy string");
    }

    /* reverse */
    {
        char s[] = "abcdef";
        reverse(s, 6);
        CHECK(my_strcmp(s, "fedcba") == 0, "reverse abcdef");
    }
    {
        char s[] = "a";
        reverse(s, 1);
        CHECK(s[0] == 'a', "reverse single char");
    }

    /* itoa */
    {
        char buf[32];
        my_itoa(0, buf);
        CHECK(my_strcmp(buf, "0") == 0, "itoa(0)");
        my_itoa(12345, buf);
        CHECK(my_strcmp(buf, "12345") == 0, "itoa(12345)");
        my_itoa(-42, buf);
        CHECK(my_strcmp(buf, "-42") == 0, "itoa(-42)");
    }

    /* Case conversion */
    {
        char s[] = "Hello World 123!";
        for (char *p = s; *p; p++)
            if (*p >= 'A' && *p <= 'Z') *p += ('a' - 'A');
        CHECK(my_strcmp(s, "hello world 123!") == 0, "to-lower-case");
    }

    printf("string_ops: %d passed, %d failed\n", pass, fail);
    return fail ? EXIT_FAILURE : EXIT_SUCCESS;
}

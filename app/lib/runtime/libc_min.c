#include <stddef.h>
#include <stdint.h>

void *memcpy(void *dst, const void *src, size_t n)
{
    unsigned char *d = (unsigned char *)dst;
    const unsigned char *s = (const unsigned char *)src;
    if ((((uintptr_t)d ^ (uintptr_t)s) & (sizeof(uint32_t) - 1u)) == 0) {
        while (((uintptr_t)d & (sizeof(uint32_t) - 1u)) && n) {
            *d++ = *s++;
            n--;
        }

        uint32_t *dw = (uint32_t *)d;
        const uint32_t *sw = (const uint32_t *)s;
        while (n >= sizeof(uint32_t)) {
            *dw++ = *sw++;
            n -= sizeof(uint32_t);
        }

        d = (unsigned char *)dw;
        s = (const unsigned char *)sw;
    }

    while (n--) *d++ = *s++;
    return dst;
}

void *memmove(void *dst, const void *src, size_t n)
{
    unsigned char *d = (unsigned char *)dst;
    const unsigned char *s = (const unsigned char *)src;
    if (d < s) {
        while (n--) *d++ = *s++;
    } else {
        d += n;
        s += n;
        while (n--) *--d = *--s;
    }
    return dst;
}

void *memset(void *dst, int c, size_t n)
{
    unsigned char *d = (unsigned char *)dst;
    unsigned char byte = (unsigned char)c;
    uint32_t word = byte;
    word |= word << 8;
    word |= word << 16;

    while (((uintptr_t)d & (sizeof(uint32_t) - 1u)) && n) {
        *d++ = byte;
        n--;
    }

    uint32_t *dw = (uint32_t *)d;
    while (n >= sizeof(uint32_t)) {
        *dw++ = word;
        n -= sizeof(uint32_t);
    }

    d = (unsigned char *)dw;
    while (n--) *d++ = byte;
    return dst;
}

int memcmp(const void *lhs, const void *rhs, size_t n)
{
    const unsigned char *a = (const unsigned char *)lhs;
    const unsigned char *b = (const unsigned char *)rhs;
    while (n--) {
        if (*a != *b) return (int)*a - (int)*b;
        a++;
        b++;
    }
    return 0;
}

size_t strlen(const char *s)
{
    const char *p = s;
    while (*p) p++;
    return (size_t)(p - s);
}

char *strcpy(char *dst, const char *src)
{
    char *out = dst;
    while ((*dst++ = *src++) != '\0') {
    }
    return out;
}

char *strcat(char *dst, const char *src)
{
    strcpy(dst + strlen(dst), src);
    return dst;
}

char *strncat(char *dst, const char *src, size_t n)
{
    char *out = dst;
    dst += strlen(dst);
    while (n-- && *src) *dst++ = *src++;
    *dst = '\0';
    return out;
}

int strcmp(const char *lhs, const char *rhs)
{
    while (*lhs && *lhs == *rhs) {
        lhs++;
        rhs++;
    }
    return *(const unsigned char *)lhs - *(const unsigned char *)rhs;
}

int strncmp(const char *lhs, const char *rhs, size_t n)
{
    while (n-- && *lhs && *lhs == *rhs) {
        lhs++;
        rhs++;
    }
    if (n == (size_t)-1) return 0;
    return *(const unsigned char *)lhs - *(const unsigned char *)rhs;
}

int atoi(const char *s)
{
    int sign = 1;
    int value = 0;
    while (*s == ' ' || *s == '\t' || *s == '\n' || *s == '\r') s++;
    if (*s == '-') {
        sign = -1;
        s++;
    } else if (*s == '+') {
        s++;
    }
    while (*s >= '0' && *s <= '9') value = value * 10 + (*s++ - '0');
    return sign * value;
}

char *itoa(int value, char *str, int base)
{
    char tmp[34];
    unsigned int u;
    int pos = 0;
    int neg = 0;
    const char *digits = "0123456789abcdefghijklmnopqrstuvwxyz";

    if (base < 2 || base > 36) {
        str[0] = '\0';
        return str;
    }

    if (base == 10 && value < 0) {
        neg = 1;
        u = (unsigned int)(-(value + 1)) + 1u;
    } else {
        u = (unsigned int)value;
    }

    do {
        tmp[pos++] = digits[u % (unsigned int)base];
        u /= (unsigned int)base;
    } while (u != 0);
    if (neg) tmp[pos++] = '-';

    for (int i = 0; i < pos; i++) str[i] = tmp[pos - 1 - i];
    str[pos] = '\0';
    return str;
}

#ifdef RAPT_LIBC_MIN_MALLOC
extern char *_sbrk(int size);

void *malloc(size_t size)
{
    uintptr_t aligned = (size + 7u) & ~(uintptr_t)7u;
    if (aligned == 0) aligned = 8;
    return _sbrk((int)aligned);
}
#endif
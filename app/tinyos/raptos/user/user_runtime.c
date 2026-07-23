#include "user.h"

int USER_TEXT syscall3(uint32_t number, uint32_t arg0, uint32_t arg1, uint32_t arg2) {
    register uint32_t a0 __asm__("a0") = arg0;
    register uint32_t a1 __asm__("a1") = arg1;
    register uint32_t a2 __asm__("a2") = arg2;
    register uint32_t a7 __asm__("a7") = number;
    __asm__ volatile("ecall" : "+r"(a0) : "r"(a1), "r"(a2), "r"(a7) : "memory");
    return (int)a0;
}

uint32_t USER_TEXT text_length(const char *text) {
    uint32_t length = 0;
    while (text[length]) length++;
    return length;
}

int USER_TEXT text_equal(const char *left, const char *right) {
    while (*left && *left == *right) { left++; right++; }
    return *left == *right;
}

void USER_TEXT print(const char *text) {
    syscall3(SYS_WRITE, 1, (uint32_t)text, text_length(text));
}

void USER_TEXT print_error(const char *command, const char *message) {
    print(command);
    print(message);
}

void USER_TEXT print_uint(uint32_t value) {
    char digits[10];
    int count = 0;
    do {
        digits[count++] = (char)('0' + value % 10);
        value /= 10;
    } while (value);
    while (count) {
        char digit = digits[--count];
        syscall3(SYS_WRITE, 1, (uint32_t)&digit, 1);
    }
}

void USER_TEXT print_hex(uint32_t value) {
    static const char digits[] USER_DATA = "0123456789abcdef";
    char text[11];
    text[0] = '0';
    text[1] = 'x';
    for (int index = 0; index < 8; index++)
        text[2 + index] = digits[(value >> (28 - index * 4)) & 0xf];
    text[10] = 0;
    print(text);
}

int USER_TEXT parse_uint(const char *text, uint32_t *value) {
    if (!*text) return -1;
    uint32_t base = 10;
    if (text[0] == '0' && (text[1] == 'x' || text[1] == 'X')) {
        base = 16;
        text += 2;
        if (!*text) return -1;
    }
    uint32_t result = 0;
    while (*text) {
        uint32_t digit;
        if (*text >= '0' && *text <= '9') digit = (uint32_t)(*text - '0');
        else if (*text >= 'a' && *text <= 'f') digit = (uint32_t)(*text - 'a' + 10);
        else if (*text >= 'A' && *text <= 'F') digit = (uint32_t)(*text - 'A' + 10);
        else return -1;
        if (digit >= base || result > (0xffffffffu - digit) / base) return -1;
        result = result * base + digit;
        text++;
    }
    *value = result;
    return 0;
}
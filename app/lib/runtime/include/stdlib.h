#ifndef RAPT_LIBC_MIN_STDLIB_H
#define RAPT_LIBC_MIN_STDLIB_H

#include <stddef.h>

int atoi(const char *s);
char *itoa(int value, char *str, int base);
void *malloc(size_t size);

#endif
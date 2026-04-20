/* Freestanding stub — implementations in minilib.c */
#ifndef _EMBENCH_STDIO_H
#define _EMBENCH_STDIO_H

#include <stdarg.h>
#include <stddef.h>

int printf(const char *, ...) __attribute__((format(printf, 1, 2)));
int vprintf(const char *, va_list);
int putchar(int);
int puts(const char *);

#define NULL ((void *)0)

/* snprintf / sprintf — not implemented, stub to satisfy prototypes */
int snprintf(char *, size_t, const char *, ...);
int sprintf(char *, const char *, ...);

#endif

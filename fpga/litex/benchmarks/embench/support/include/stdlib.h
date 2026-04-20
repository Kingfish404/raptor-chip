/* Freestanding stub — implementations in minilib.c */
#ifndef _EMBENCH_STDLIB_H
#define _EMBENCH_STDLIB_H

#include <stddef.h>

int abs(int);
long labs(long);
int atoi(const char *);
int rand(void);
void srand(unsigned int);
void *malloc(size_t);
void *calloc(size_t, size_t);
void free(void *);
void exit(int) __attribute__((noreturn));
void abort(void) __attribute__((noreturn));

#define EXIT_SUCCESS 0
#define EXIT_FAILURE 1
#define RAND_MAX 0x7FFF
#define NULL ((void *)0)

#endif

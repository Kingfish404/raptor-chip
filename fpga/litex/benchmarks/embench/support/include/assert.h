/* Freestanding stub — assert handler in minilib.c */
#ifndef _EMBENCH_ASSERT_H
#define _EMBENCH_ASSERT_H

void __assert_func(const char *, int, const char *, const char *)
    __attribute__((noreturn));

#ifdef NDEBUG
#define assert(x) ((void)0)
#else
#define assert(x) \
    ((x) ? (void)0 : __assert_func(__FILE__, __LINE__, __func__, #x))
#endif

#endif

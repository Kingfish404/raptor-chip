/* Freestanding stub — _ctype_ table in minilib.c */
#ifndef _EMBENCH_CTYPE_H
#define _EMBENCH_CTYPE_H

/* Newlib-compatible ctype flag bits */
#define _U 0x01 /* upper */
#define _L 0x02 /* lower */
#define _N 0x04 /* digit */
#define _S 0x08 /* space */
#define _P 0x10 /* punct */
#define _C 0x20 /* control */
#define _X 0x40 /* hex digit */
#define _B 0x80 /* blank */

extern const char _ctype_[];

#define isalpha(c) (_ctype_[(unsigned char)(c) + 1] & (_U | _L))
#define isupper(c) (_ctype_[(unsigned char)(c) + 1] & _U)
#define islower(c) (_ctype_[(unsigned char)(c) + 1] & _L)
#define isdigit(c) (_ctype_[(unsigned char)(c) + 1] & _N)
#define isxdigit(c) (_ctype_[(unsigned char)(c) + 1] & (_N | _X))
#define isspace(c) (_ctype_[(unsigned char)(c) + 1] & _S)
#define ispunct(c) (_ctype_[(unsigned char)(c) + 1] & _P)
#define isalnum(c) (_ctype_[(unsigned char)(c) + 1] & (_U | _L | _N))
#define isprint(c) (_ctype_[(unsigned char)(c) + 1] & (_U | _L | _N | _P | _B))
#define iscntrl(c) (_ctype_[(unsigned char)(c) + 1] & _C)

static inline int toupper(int c) { return islower(c) ? c - 'a' + 'A' : c; }
static inline int tolower(int c) { return isupper(c) ? c - 'A' + 'a' : c; }

#endif

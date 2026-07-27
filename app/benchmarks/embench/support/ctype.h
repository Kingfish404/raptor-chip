#ifndef EMBENCH_CTYPE_H
#define EMBENCH_CTYPE_H

static inline int isdigit(int c)
{
    return c >= '0' && c <= '9';
}

static inline int isxdigit(int c)
{
    return isdigit(c) || (c >= 'a' && c <= 'f') ||
           (c >= 'A' && c <= 'F');
}

static inline int isspace(int c)
{
    return c == ' ' || (c >= '\t' && c <= '\r');
}

static inline int tolower(int c)
{
    return c >= 'A' && c <= 'Z' ? c + ('a' - 'A') : c;
}

#endif
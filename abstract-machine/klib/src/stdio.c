#include <am.h>
#include <klib.h>
#include <klib-macros.h>
#include <stdarg.h>

#if !defined(__ISA_NATIVE__) || defined(__NATIVE_USE_KLIB__)

int printf(const char *fmt, ...)
{
  panic("Not implemented");
}

int vsprintf(char *out, const char *fmt, va_list ap)
{
  panic("Not implemented");
}

int sprintf(char *out, const char *fmt, ...)
{
  char *pout = out, *p;
  int d;
  va_list ap;
  va_start(ap, fmt);
  for (size_t i = 0; fmt[i] != '\0'; i++)
  {
    switch (fmt[i])
    {
    case '%':
      switch (fmt[++i])
      {
      case 'd':
        d = va_arg(ap, int);
        char cs[8] = {'0'};
        p = cs;
        while (d != 0)
        {
          *p = d % 10 + '0';
          d /= 10;
          p++;
        }
        while (p != cs)
        {
          p--;
          *pout = *p;
          pout++;
        }
        *(pout + 1) = '\0';
        break;
      case 's':
        p = va_arg(ap, char *);
        strcpy(pout, p);
        pout += strlen(p);
        break;
      }
      break;
    default:
      (*pout) = fmt[i];
      pout++;
      break;
    }
  }
  va_end(ap);
}

int snprintf(char *out, size_t n, const char *fmt, ...)
{
  panic("Not implemented");
}

int vsnprintf(char *out, size_t n, const char *fmt, va_list ap)
{
  panic("Not implemented");
}

#endif

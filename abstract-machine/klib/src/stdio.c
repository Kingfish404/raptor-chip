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
        if (d < 0)
        {
          *pout = '-';
          pout++;
        }
        char *s_p = pout;
        do
        {
          int td = d % 10;
          *pout = '0' + (td >= 0 ? td : -td);
          pout++;
          d /= 10;
        } while (d != 0);
        char *e_p = pout - 1;
        while (s_p < e_p)
        {
          char tmp = *s_p;
          *s_p = *e_p;
          *e_p = tmp;
          s_p++;
          e_p--;
        }
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
    (*pout) = '\0';
  }
  va_end(ap);
  return 0;
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

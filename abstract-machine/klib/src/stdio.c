#include <am.h>
#include <klib.h>
#include <klib-macros.h>
#include <stdarg.h>
#include <stdint.h>

#if !defined(__ISA_NATIVE__) || defined(__NATIVE_USE_KLIB__)

#define SPRINT_BUF_SIZE 1024

static char sprint_buf[SPRINT_BUF_SIZE];

int printf(const char *fmt, ...)
{
  va_list ap;
  va_start(ap, fmt);
  int n = vsprintf(sprint_buf, fmt, ap);
  va_end(ap);
  putstr(sprint_buf);
  return n;
}

int vsprintf(char *out, const char *fmt, va_list ap)
{
  int buf_count = 0, ret = 0;
  char *pout = out, *p;
  for (size_t i = 0; fmt[i] != '\0'; i++)
  {
    switch (fmt[i])
    {
    case '%':
      switch (fmt[++i])
      {
      case 'l':
      {
        break;
      }
      case 'u':
      {
        uint32_t d = va_arg(ap, int);
        char *s_p = pout;
        do
        {
          int td = d % 10;
          *pout = '0' + (td >= 0 ? td : -td);
          pout++;
          buf_count++;
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
      }
      case 'd':
      {
        int d = va_arg(ap, int);
        if (d < 0)
        {
          *pout = '-';
          pout++;
          buf_count++;
        }
        char *s_p = pout;
        do
        {
          int td = d % 10;
          *pout = '0' + (td >= 0 ? td : -td);
          pout++;
          buf_count++;
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
      }
      break;
      case 'p':
      case 'x':
      {
        uint32_t d = va_arg(ap, uint32_t);
        char *s_p = pout;
        do
        {
          int td = d % 16;
          *pout = (td >= 0 && td <= 9) ? '0' + td : 'a' + td - 10;
          pout++;
          buf_count++;
          d /= 16;
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
      }
      break;
      case 's':
      {
        p = va_arg(ap, char *);
        strcpy(pout, p);
        pout += strlen(p);
      }
      break;
      case 'c':
      {
        char c = va_arg(ap, int);
        *pout = c;
        pout++;
      }
      break;
      }
      break;
    default:
      (*pout) = fmt[i];
      pout++;
      buf_count++;
      break;
    }
    (*pout) = '\0';
    if (buf_count + 1 == SPRINT_BUF_SIZE)
    {
      ret = -1;
      break;
    }
  }
  return ret;
}

int sprintf(char *out, const char *fmt, ...)
{
  va_list ap;
  va_start(ap, fmt);
  int ret = vsprintf(out, fmt, ap);
  va_end(ap);
  return ret;
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

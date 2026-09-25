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
  int written = 0;
  char *pout = out;
  for (size_t i = 0; fmt[i] != '\0'; i++)
  {
    if (fmt[i] != '%')
    {
      *pout++ = fmt[i];
      written++;
      continue;
    }

    i++;
    if (fmt[i] == '%')
    {
      *pout++ = '%';
      written++;
      continue;
    }

    int zero_pad = 0;
    int left_align = 0;
    int width = 0;
    if (fmt[i] == '0')
    {
      zero_pad = 1;
      i++;
    }
    if (fmt[i] == '-')
    {
      left_align = 1;
      zero_pad = 0;
      i++;
    }
    while (fmt[i] >= '0' && fmt[i] <= '9')
    {
      width = width * 10 + (fmt[i] - '0');
      i++;
    }

    int long_count = 0;
    while (fmt[i] == 'l')
    {
      long_count++;
      i++;
    }

    char text[32];
    const char *string_value = NULL;
    int length = 0;
    char sign = '\0';
    unsigned long long value = 0;
    unsigned int base = 10;
    int numeric = 0;
    switch (fmt[i])
    {
    case 'u':
    case 'x':
      numeric = 1;
      base = fmt[i] == 'u' ? 10 : 16;
      if (long_count > 1)
        value = va_arg(ap, unsigned long long);
      else if (long_count == 1)
        value = va_arg(ap, unsigned long);
      else
        value = va_arg(ap, unsigned int);
      break;
    case 'p':
      numeric = 1;
      base = 16;
      value = (uintptr_t)va_arg(ap, void *);
      break;
    case 'd':
    case 'i':
      numeric = 1;
      if (long_count > 1)
      {
        long long number = va_arg(ap, long long);
        if (number < 0)
        {
          sign = '-';
          value = (unsigned long long)(-(number + 1)) + 1;
        }
        else
          value = (unsigned long long)number;
      }
      else if (long_count == 1)
      {
        long number = va_arg(ap, long);
        if (number < 0)
        {
          sign = '-';
          value = (unsigned long long)(-(number + 1)) + 1;
        }
        else
          value = (unsigned long long)number;
      }
      else
      {
        int number = va_arg(ap, int);
        if (number < 0)
        {
          sign = '-';
          value = (unsigned int)(-(number + 1)) + 1;
        }
        else
          value = (unsigned int)number;
      }
      break;
    case 's':
      string_value = va_arg(ap, const char *);
      length = strlen(string_value);
      break;
    case 'c':
      text[length++] = (char)va_arg(ap, int);
      break;
    default:
      text[length++] = fmt[i];
      break;
    }

    if (numeric)
    {
      do
      {
        unsigned int digit = value % base;
        text[length++] = digit < 10 ? '0' + digit : 'a' + digit - 10;
        value /= base;
      } while (value != 0 && length < (int)sizeof(text) - 1);
      for (int left = 0, right = length - 1; left < right; left++, right--)
      {
        char tmp = text[left];
        text[left] = text[right];
        text[right] = tmp;
      }
    }

    int padding = width - length - (sign != '\0');
    if (!left_align && !zero_pad)
      while (padding-- > 0)
      {
        *pout++ = ' ';
        written++;
      }
    if (sign != '\0')
    {
      *pout++ = sign;
      written++;
    }
    if (!left_align && zero_pad)
      while (padding-- > 0)
      {
        *pout++ = '0';
        written++;
      }
    for (int j = 0; j < length; j++)
    {
      *pout++ = string_value == NULL ? text[j] : string_value[j];
      written++;
    }
    if (left_align)
      while (padding-- > 0)
      {
        *pout++ = ' ';
        written++;
      }
    *pout = '\0';
  }
  *pout = '\0';
  return written;
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

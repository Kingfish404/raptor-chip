#ifndef RAPTOR_MICROBENCH_SE_AM_H
#define RAPTOR_MICROBENCH_SE_AM_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct {
  void *start;
  void *end;
} Area;

typedef struct {
  uint64_t us;
} AM_TIMER_UPTIME_T;

#define AM_TIMER_UPTIME AM_TIMER_UPTIME

extern Area heap;
uint64_t microbench_se_uptime(void);
void halt(int code) __attribute__((noreturn));

static inline bool ioe_init(void)
{
  return true;
}

#define io_read(reg) ((reg##_T){.us = microbench_se_uptime()})

#endif

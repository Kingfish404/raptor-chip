// AM timer implementation for the 20 MHz Arty vehicle, with a 1 MHz CLINT.
#include <am.h>

void __am_timer_init(void) {}

void __am_timer_uptime(AM_TIMER_UPTIME_T *uptime) {
  volatile const uint32_t *mtime = (const uint32_t *)0x0200bff8;
  uint32_t high, low, again;
  do {
    high = mtime[1];
    low = mtime[0];
    again = mtime[1];
  } while (high != again);
  uptime->us = ((uint64_t)high << 32) | low;
}

void __am_timer_rtc(AM_TIMER_RTC_T *rtc) {
  *rtc = (AM_TIMER_RTC_T){.year = 1900};
}

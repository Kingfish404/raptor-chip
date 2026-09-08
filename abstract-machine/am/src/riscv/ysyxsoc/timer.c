#include <am.h>
#include <ysyxsoc.h>

void __am_timer_init()
{
}

void __am_timer_uptime(AM_TIMER_UPTIME_T *uptime)
{
  uint32_t hi0, lo, hi1;
  do {
    asm volatile("rdtimeh %0" : "=r"(hi0));
    asm volatile("rdtime %0" : "=r"(lo));
    asm volatile("rdtimeh %0" : "=r"(hi1));
  } while (hi0 != hi1);
  // Match hdl/include/ysyxsoc/rapt_soc.svh: CLINT mtime is 10 MHz,
  // independently of the core clock. Do not interpret mtime as mcycle.
  uptime->us = (((uint64_t)hi0 << 32) | lo) / 10;

}

void __am_timer_rtc(AM_TIMER_RTC_T *rtc)
{
  rtc->second = 0;
  rtc->minute = 0;
  rtc->hour = 0;
  rtc->day = 0;
  rtc->month = 0;
  rtc->year = 1900;
}

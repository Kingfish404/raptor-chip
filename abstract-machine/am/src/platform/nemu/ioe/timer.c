#include <am.h>
#include <nemu.h>

void __am_timer_init()
{
  outl(RTC_ADDR_, 0);
  outl(RTC_ADDR_ + 4, 0);
}

void __am_timer_uptime(AM_TIMER_UPTIME_T *uptime)
{
  uptime->us = inl(RTC_ADDR_ + 4);
  uptime->us <<= 32;
  uptime->us += inl(RTC_ADDR_);
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

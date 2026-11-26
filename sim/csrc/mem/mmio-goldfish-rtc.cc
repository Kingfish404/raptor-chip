#include <common.h>
#include <memory.h>

#include <stdint.h>
#include <time.h>

// Standard Google Goldfish RTC (`google,goldfish-rtc`) at 0x00101000 (PLIC IRQ 6).
// Register layout matches Linux `drivers/rtc/rtc-goldfish.c` and QEMU `virt`.
#define GOLDFISH_RTC_IRQ 6u

void nsim_plic_raise(uint32_t irq);

static uint64_t host_mono_ns()
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static uint64_t host_wall_ns()
{
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static struct
{
    bool initialized;
    int64_t offset_ns;
    uint32_t time_high_latch;
    uint64_t alarm_ns;
    bool alarm_armed;
    bool irq_enabled;
    bool irq_pending;
} g_rtc = {false, 0, 0, 0, false, false, false};

static void rtc_ensure_init()
{
    if (!g_rtc.initialized)
    {
        g_rtc.offset_ns = (int64_t)(host_wall_ns() - host_mono_ns());
        g_rtc.initialized = true;
    }
}

static uint64_t rtc_now_ns()
{
    rtc_ensure_init();
    return (uint64_t)((int64_t)host_mono_ns() + g_rtc.offset_ns);
}

static void rtc_check_alarm()
{
    if (g_rtc.alarm_armed && rtc_now_ns() >= g_rtc.alarm_ns)
    {
        g_rtc.alarm_armed = false;
        g_rtc.irq_pending = true;
        if (g_rtc.irq_enabled)
            nsim_plic_raise(GOLDFISH_RTC_IRQ);
    }
}

void goldfish_rtc_poll()
{
    if (g_rtc.alarm_armed)
        rtc_check_alarm();
}

static uint32_t rtc_read32(uint32_t aligned)
{
    rtc_check_alarm();
    switch (aligned)
    {
    case 0x00u:
    {
        uint64_t now = rtc_now_ns();
        g_rtc.time_high_latch = (uint32_t)(now >> 32);
        return (uint32_t)(now & 0xffffffffu);
    }
    case 0x04u:
        return g_rtc.time_high_latch;
    case 0x08u:
        return (uint32_t)(g_rtc.alarm_ns & 0xffffffffu);
    case 0x0cu:
        return (uint32_t)(g_rtc.alarm_ns >> 32);
    case 0x10u:
        return g_rtc.irq_enabled ? 1u : 0u;
    case 0x18u:
        return g_rtc.alarm_armed ? 1u : 0u;
    default:
        return 0u;
    }
}

void mmio_goldfish_rtc_handle(paddr_t offset, word_t wdata, char wmask, bool is_write, word_t *data)
{
    uint32_t aligned = (uint32_t)offset & ~0x3u;
    if (!is_write)
    {
        uint32_t r32 = rtc_read32(aligned);
        if (data != NULL)
        {
            *data = ((offset & 4u) && sizeof(word_t) == 8)
                        ? (word_t)((uint64_t)r32 << 32)
                        : (word_t)r32;
        }
        return;
    }

    uint32_t val = 0;
    for (unsigned i = 0; i < 4; i++)
    {
        if ((uint8_t)wmask & (1u << i))
        {
            unsigned shift = (((unsigned)offset + i) & 3u) * 8u;
            val |= ((uint32_t)((wdata >> (8 * i)) & 0xffu)) << shift;
        }
    }

    rtc_ensure_init();
    switch (aligned)
    {
    case 0x00u:
    {
        uint64_t cur = rtc_now_ns();
        uint64_t next = (cur & ~0xffffffffull) | (uint64_t)val;
        g_rtc.offset_ns = (int64_t)(next - host_mono_ns());
        break;
    }
    case 0x04u:
    {
        uint64_t cur = rtc_now_ns();
        uint64_t next = ((uint64_t)val << 32) | (cur & 0xffffffffull);
        g_rtc.offset_ns = (int64_t)(next - host_mono_ns());
        break;
    }
    case 0x08u:
        g_rtc.alarm_ns = (g_rtc.alarm_ns & ~0xffffffffull) | (uint64_t)val;
        g_rtc.alarm_armed = true;
        rtc_check_alarm();
        break;
    case 0x0cu:
        g_rtc.alarm_ns = (g_rtc.alarm_ns & 0xffffffffull) | ((uint64_t)val << 32);
        break;
    case 0x10u:
    {
        bool prev_en = g_rtc.irq_enabled;
        g_rtc.irq_enabled = (val & 1u) != 0;
        if (g_rtc.irq_enabled && !prev_en && g_rtc.irq_pending)
            nsim_plic_raise(GOLDFISH_RTC_IRQ);
        break;
    }
    case 0x14u:
        g_rtc.alarm_armed = false;
        break;
    case 0x1cu:
        g_rtc.irq_pending = false;
        break;
    default:
        break;
    }
}

#include <am.h>
#include <ysyxsoc.h>
#include <klib-macros.h>

void __am_timer_init();

void __am_timer_rtc(AM_TIMER_RTC_T *);
void __am_timer_uptime(AM_TIMER_UPTIME_T *);
void __am_input_keybrd(AM_INPUT_KEYBRD_T *);

static void __am_uart_tx(AM_UART_TX_T *send)
{
    while ((inb(UART16550_LSR) & (0x1 << 5)) == 0x0)
        ;
    outb(UART16550_TX, send->data);
}

static void __am_uart_rx(AM_UART_RX_T *recv)
{
    recv->data = inb(UART16550_RX);
}

static void __am_timer_config(AM_TIMER_CONFIG_T *cfg)
{
    cfg->present = true;
    cfg->has_rtc = true;
}
static void __am_input_config(AM_INPUT_CONFIG_T *cfg) { cfg->present = true; }

typedef void (*handler_t)(void *buf);
static void *lut[128] = {
    [AM_UART_TX] = __am_uart_tx,
    [AM_UART_RX] = __am_uart_rx,
    [AM_TIMER_CONFIG] = __am_timer_config,
    [AM_TIMER_RTC] = __am_timer_rtc,
    [AM_TIMER_UPTIME] = __am_timer_uptime,
    [AM_INPUT_KEYBRD] = __am_input_keybrd,
};

static void fail(void *buf) { panic("access nonexist register"); }

bool ioe_init()
{
    for (int i = 0; i < LENGTH(lut); i++)
        if (!lut[i])
            lut[i] = fail;
    __am_timer_init();
    return true;
}

void ioe_read(int reg, void *buf) { ((handler_t)lut[reg])(buf); }
void ioe_write(int reg, void *buf) { ((handler_t)lut[reg])(buf); }

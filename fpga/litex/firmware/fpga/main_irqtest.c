/*
 * Raptor minimal IRQ repro firmware.
 *
 * Goal
 * ----
 * Smallest possible binary that exercises the Raptor IRQ delivery / `mret`
 * path. The LiteX BIOS hangs as soon as its IRQ-driven UART driver fires
 * the first TX interrupt — but it's a moving target with many CSR ops in
 * the ISR. This firmware isolates the IRQ path:
 *
 *   1.  Set our own mtvec (boot.S already did, install a richer one here).
 *   2.  Enable UART RX event (uart_ev_enable.RX = 1).
 *   3.  Set mie.MEIE  (bit 11) and mstatus.MIE.
 *   4.  Main loop: wfi.
 *   5.  ISR: print "IRQ#<n> rx=<byte>", ack the UART event, mret.
 *
 * Outcomes
 * --------
 *   * Type a key over UART:
 *     - "IRQ#1 rx=0xNN" appears, then more on each keypress  -> IRQ path OK.
 *     - "IRQ#1 ..." then hang on second key                  -> mret bug.
 *     - hang on first key (CPU never reaches ISR)            -> entry bug.
 *     - hang at boot (before any key)                        -> setup bug
 *       (e.g. wfi never wakes — interrupt[0] line not pulsing).
 *
 * Build:  make firmware-fpga FW_FPGA_TARGET=irqtest
 * Run:    make fpga-build BOOT_MODE=custom FW_FPGA_TARGET=irqtest && \
 *         make fpga-flash && screen /dev/tty.usbserial-XXX 115200
 */

#include <stdint.h>

/* LiteUART CSR layout (matches main.c). */
#define UART_BASE         0xf0001800u
#define UART_RXTX         (UART_BASE + 0x00)
#define UART_TXFULL       (UART_BASE + 0x04)
#define UART_RXEMPTY      (UART_BASE + 0x08)
#define UART_EV_STATUS    (UART_BASE + 0x0c)
#define UART_EV_PENDING   (UART_BASE + 0x10)
#define UART_EV_ENABLE    (UART_BASE + 0x14)
#define UART_EV_TX        0x1u
#define UART_EV_RX        0x2u

#define MIE_MEIE          (1u << 11)
#define MSTATUS_MIE       (1u << 3)

static inline void mmio_w(uintptr_t a, uint32_t v) { *(volatile uint32_t *)a = v; }
static inline uint32_t mmio_r(uintptr_t a)         { return *(volatile uint32_t *)a; }

/* --- UART primitives (polling — not the path under test). --- */
static void uart_putc(char c)
{
    if (c == '\n') { while (mmio_r(UART_TXFULL)) {} mmio_w(UART_RXTX, '\r'); }
    while (mmio_r(UART_TXFULL)) {}
    mmio_w(UART_RXTX, (uint32_t)(uint8_t)c);
}

static void uart_puts(const char *s) { while (*s) { uart_putc(*s++); } }

static void uart_put_hex8(uint8_t v)
{
    static const char d[] = "0123456789abcdef";
    uart_putc(d[(v >> 4) & 0xf]);
    uart_putc(d[v & 0xf]);
}

static void uart_put_u32(uint32_t v)
{
    char buf[11]; int i = 0;
    if (!v) { uart_putc('0'); return; }
    while (v) { buf[i++] = '0' + (v % 10); v /= 10; }
    while (i--) uart_putc(buf[i]);
}

/* --- CSR helpers. --- */
#define CSR_R(name) ({ uint32_t v; asm volatile("csrr %0," #name : "=r"(v)); v; })
#define CSR_W(name, v) asm volatile("csrw " #name ", %0" :: "r"(v))
#define CSR_S(name, v) asm volatile("csrs " #name ", %0" :: "r"(v))
#define CSR_C(name, v) asm volatile("csrc " #name ", %0" :: "r"(v))

/* --- Volatile state shared with ISR. --- */
static volatile uint32_t g_irq_count;
static volatile uint8_t  g_last_rx;
static volatile uint32_t g_last_mcause;
static volatile uint32_t g_last_mepc;

/* --- Trap handler.  Naked: must save/restore everything we touch. --- */
__attribute__((naked, aligned(4)))
static void irq_trap_entry(void)
{
    /* Save caller-save regs: ra,t0..t6,a0..a7  (16 words). */
    asm volatile(
        "addi sp, sp, -64        \n"
        "sw   ra,  0(sp)         \n"
        "sw   t0,  4(sp)         \n"
        "sw   t1,  8(sp)         \n"
        "sw   t2, 12(sp)         \n"
        "sw   a0, 16(sp)         \n"
        "sw   a1, 20(sp)         \n"
        "sw   a2, 24(sp)         \n"
        "sw   a3, 28(sp)         \n"
        "sw   a4, 32(sp)         \n"
        "sw   a5, 36(sp)         \n"
        "sw   a6, 40(sp)         \n"
        "sw   a7, 44(sp)         \n"
        "sw   t3, 48(sp)         \n"
        "sw   t4, 52(sp)         \n"
        "sw   t5, 56(sp)         \n"
        "sw   t6, 60(sp)         \n"
        "call irq_handler        \n"
        "lw   ra,  0(sp)         \n"
        "lw   t0,  4(sp)         \n"
        "lw   t1,  8(sp)         \n"
        "lw   t2, 12(sp)         \n"
        "lw   a0, 16(sp)         \n"
        "lw   a1, 20(sp)         \n"
        "lw   a2, 24(sp)         \n"
        "lw   a3, 28(sp)         \n"
        "lw   a4, 32(sp)         \n"
        "lw   a5, 36(sp)         \n"
        "lw   a6, 40(sp)         \n"
        "lw   a7, 44(sp)         \n"
        "lw   t3, 48(sp)         \n"
        "lw   t4, 52(sp)         \n"
        "lw   t5, 56(sp)         \n"
        "lw   t6, 60(sp)         \n"
        "addi sp, sp, 64         \n"
        "mret                    \n"
    );
}

/* --- Real handler.  Called from naked trampoline. --- */
void irq_handler(void)
{
    g_last_mcause = CSR_R(mcause);
    g_last_mepc   = CSR_R(mepc);

    /* Drain RX queue — pop every available byte (one per ev_pending ack). */
    uart_puts("\nIRQ #");
    uart_put_u32(++g_irq_count);
    uart_puts("  mcause=0x");
    {
        uint32_t v = g_last_mcause;
        for (int i = 7; i >= 0; --i) {
            char d = "0123456789abcdef"[(v >> (i * 4)) & 0xf];
            uart_putc(d);
        }
    }
    uart_puts("  mepc=0x");
    {
        uint32_t v = g_last_mepc;
        for (int i = 7; i >= 0; --i) {
            char d = "0123456789abcdef"[(v >> (i * 4)) & 0xf];
            uart_putc(d);
        }
    }

    /* Read all pending RX bytes, ack via ev_pending. */
    while (!mmio_r(UART_RXEMPTY)) {
        uint8_t b = (uint8_t)(mmio_r(UART_RXTX) & 0xff);
        g_last_rx = b;
        mmio_w(UART_EV_PENDING, UART_EV_RX);
        uart_puts("  rx=0x");
        uart_put_hex8(b);
    }
    uart_putc('\n');
}

/* Same trap_dump that boot.S _trap_entry calls — reused if a synchronous
 * exception fires (mcause MSB clear). The IRQ trampoline above replaces
 * mtvec so we should never enter here unless something goes wrong before
 * the IRQ setup is complete. */
void trap_dump(uint32_t mcause, uint32_t mepc, uint32_t mtval, uint32_t old_sp)
{
    (void)old_sp;
    uart_puts("\n!!! TRAP !!!  mcause=0x");
    for (int i = 7; i >= 0; --i) uart_putc("0123456789abcdef"[(mcause >> (i * 4)) & 0xf]);
    uart_puts(" mepc=0x");
    for (int i = 7; i >= 0; --i) uart_putc("0123456789abcdef"[(mepc >> (i * 4)) & 0xf]);
    uart_puts(" mtval=0x");
    for (int i = 7; i >= 0; --i) uart_putc("0123456789abcdef"[(mtval >> (i * 4)) & 0xf]);
    uart_puts("\nhalted.\n");
}

void main(unsigned long hartid)
{
    (void)hartid;
    uart_puts("\n[irqtest] Raptor minimal IRQ probe\n");
    uart_puts("  built: " __DATE__ " " __TIME__ "\n");

    /* 1. Drain any stale RX bytes / events first. */
    while (!mmio_r(UART_RXEMPTY)) { (void)mmio_r(UART_RXTX); }
    mmio_w(UART_EV_PENDING, UART_EV_RX | UART_EV_TX);

    /* 2. Install our IRQ trap entry as mtvec (direct mode). */
    CSR_W(mtvec, (uint32_t)(uintptr_t)irq_trap_entry);
    uart_puts("  mtvec installed @ 0x");
    {
        uint32_t v = (uint32_t)(uintptr_t)irq_trap_entry;
        for (int i = 7; i >= 0; --i) uart_putc("0123456789abcdef"[(v >> (i * 4)) & 0xf]);
    }
    uart_putc('\n');

    /* 3. Enable RX event source on UART (bit 1). */
    mmio_w(UART_EV_ENABLE, UART_EV_RX);

    /* 4. Set mie.MEIE then mstatus.MIE.  Print the values back so we can
     *    verify they actually stuck (Raptor CSR write hazard sanity check). */
    CSR_W(mie, MIE_MEIE);
    uint32_t mie_rb = CSR_R(mie);
    uart_puts("  mie       = 0x"); for (int i = 7; i >= 0; --i) uart_putc("0123456789abcdef"[(mie_rb >> (i * 4)) & 0xf]); uart_putc('\n');

    CSR_S(mstatus, MSTATUS_MIE);
    uint32_t mstatus_rb = CSR_R(mstatus);
    uart_puts("  mstatus   = 0x"); for (int i = 7; i >= 0; --i) uart_putc("0123456789abcdef"[(mstatus_rb >> (i * 4)) & 0xf]); uart_putc('\n');

    uart_puts("\nReady. Type any key to trigger an IRQ.\n");

    /* 5. Sleep loop.  wfi may not be implemented; a tight loop also works. */
    for (;;) {
        asm volatile("wfi");
        /* Heartbeat — 1 dot per ~10M iterations so we know wfi is waking. */
    }
}

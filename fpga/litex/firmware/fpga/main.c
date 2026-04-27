/*
 * Raptor Tang Mega 138K Pro — interactive bring-up shell.
 *
 * No libc, no printf, no LiteX BIOS — talks directly to the LiteX `liteuart`
 * CSR. Provides a tiny line-edited shell with a handful of built-in apps:
 *
 *   help        list commands
 *   info        SoC + build info, cycle counter sanity check
 *   banner      ASCII-art logo
 *   echo ARG... echo arguments
 *   hello       hello world
 *   cycles      print rdcycle delta over a fixed busy loop
 *   primes [N]  print primes up to N (default 200)
 *   fib [N]     print fib(0..N-1)  (default 24)
 *   memtest     write/read pattern over SRAM scratch region
 *   mandelbrot  ASCII mandelbrot (fixed-point)
 *   donut       Andy Sloane's spinning donut, fixed-point port
 *   coremark    explain why CoreMark does not fit in 32K ROM / 8K SRAM
 *   clear       ANSI clear-screen
 *   reboot      jump to reset vector
 *
 * Memory budget (must agree with link.ld):
 *   ROM   = 32 KB @ 0x20000000   (.text/.rodata/.data load image)
 *   SRAM  =  8 KB @ 0x0f000000   (.data/.bss + stack)
 * .bss kept minimal — large per-app state lives on the stack so it doesn't
 * permanently consume SRAM, and string tables live in .rodata (ROM).
 */

#include <stdint.h>
#include <stddef.h>

/* ============================================================
 * LiteX liteuart CSR layout (see build/.../csr.csv).
 * ============================================================ */
#define UART_BASE 0xf0001800u
#define UART_RXTX (UART_BASE + 0x00)
#define UART_TXFULL (UART_BASE + 0x04)
#define UART_RXEMPTY (UART_BASE + 0x08)
#define UART_EV_PENDING (UART_BASE + 0x10)
#define UART_EV_RX_MASK 0x2u

static inline void mmio_write(uintptr_t addr, uint32_t v)
{
    *(volatile uint32_t *)addr = v;
}

static inline uint32_t mmio_read(uintptr_t addr)
{
    return *(volatile uint32_t *)addr;
}

/* ============================================================
 * UART primitives.
 * ============================================================ */
static void uart_putc_raw(char c)
{
    while (mmio_read(UART_TXFULL))
    { /* spin */
    }
    mmio_write(UART_RXTX, (uint32_t)(uint8_t)c);
}

static void uart_putc(char c)
{
    if (c == '\n')
    {
        uart_putc_raw('\r');
    }
    uart_putc_raw(c);
}

static void uart_puts(const char *s)
{
    while (*s)
    {
        uart_putc(*s++);
    }
}

/* Non-blocking poll. Returns -1 if no byte, else 0..255. Pops the FIFO via
 * the ev_pending RX bit (writing the byte alone does not advance it). */
static int uart_getc_nonblock(void)
{
    if (mmio_read(UART_RXEMPTY))
    {
        return -1;
    }
    int b = (int)(mmio_read(UART_RXTX) & 0xff);
    mmio_write(UART_EV_PENDING, UART_EV_RX_MASK);
    return b;
}

static char uart_getc(void)
{
    int c;
    while ((c = uart_getc_nonblock()) < 0)
    { /* spin */
    }
    return (char)c;
}

/* ============================================================
 * Number formatting (no libc).
 * ============================================================ */
static void uart_put_hex32(uint32_t v)
{
    static const char digits[] = "0123456789abcdef";
    uart_puts("0x");
    for (int i = 7; i >= 0; --i)
    {
        uart_putc(digits[(v >> (i * 4)) & 0xf]);
    }
}

static void uart_put_u32(uint32_t v)
{
    char buf[11];
    int i = 0;
    if (v == 0)
    {
        uart_putc('0');
        return;
    }
    while (v && i < (int)sizeof(buf))
    {
        buf[i++] = '0' + (v % 10);
        v /= 10;
    }
    while (i--)
    {
        uart_putc(buf[i]);
    }
}

/* ============================================================
 * RISC-V helpers.
 * ============================================================ */
static uint32_t rdcycle32(void)
{
    uint32_t v;
    asm volatile("csrr %0, cycle" : "=r"(v));
    return v;
}

static uint32_t rdinstret32(void)
{
    uint32_t v;
    asm volatile("csrr %0, instret" : "=r"(v));
    return v;
}

/* Print "<integer>.<2-digit-frac>" of (num / den) using only 32-bit
 * unsigned division (RV32M `divu`/`remu`). Avoids pulling __udivdi3 etc.
 * Caveat: if `den < 100` the fractional digits may be 0 — fine for the
 * sub-second command-level workloads here. */
static void uart_put_ratio_q2(uint32_t num, uint32_t den)
{
    if (den == 0)
    {
        uart_puts("inf");
        return;
    }
    uint32_t whole = num / den;
    uint32_t rem   = num - whole * den;
    /* `den / 100` may be zero for tiny denominators; clamp so frac becomes
     * 0 rather than dividing by zero. */
    uint32_t step  = den / 100u;
    uint32_t frac  = (step > 0) ? (rem / step) : 0;
    if (frac > 99)
    {
        frac = 99;
    }
    uart_put_u32(whole);
    uart_putc('.');
    if (frac < 10)
    {
        uart_putc('0');
    }
    uart_put_u32(frac);
}

static void busy_loop(uint32_t n)
{
    /* Volatile counter prevents the loop from being optimised away. */
    for (volatile uint32_t i = 0; i < n; ++i)
    {
        asm volatile("" ::: "memory");
    }
}

/* Soft "reboot" — jump to reset vector. No state preserved. */
extern void _start(void);
static void reboot(void)
{
    uart_puts("[reboot]\n");
    _start();
}

/* ============================================================
 * Trap dumper — called from boot.S _trap_entry. Prints
 * mcause/mepc/mtval and the decoded cause then halts. Used to
 * diagnose silent FPGA hangs (Step 1 of IRQ-path investigation).
 *
 * Avoid printf, malloc, complex stack frames — runs on the
 * dedicated 256 B _trap_stack and the main system may be in
 * an arbitrary state.
 * ============================================================ */
static const char *trap_cause_name(uint32_t mcause)
{
    if (mcause & 0x80000000u)
    {
        return "INTERRUPT";
    }
    switch (mcause & 0x7fffffffu)
    {
    case  0: return "instr addr misaligned";
    case  1: return "instr access fault";
    case  2: return "illegal instr";
    case  3: return "breakpoint";
    case  4: return "load addr misaligned";
    case  5: return "load access fault";
    case  6: return "store addr misaligned";
    case  7: return "store access fault";
    case  8: return "ecall U";
    case 11: return "ecall M";
    case 12: return "instr page fault";
    case 13: return "load page fault";
    case 15: return "store page fault";
    default: return "?";
    }
}

void trap_dump(uint32_t mcause, uint32_t mepc, uint32_t mtval, uint32_t old_sp)
{
    (void)old_sp;
    uart_puts("\n!!! TRAP !!!\n  mcause = ");
    uart_put_hex32(mcause);
    uart_puts("  (");
    uart_puts(trap_cause_name(mcause));
    uart_puts(")\n  mepc   = ");
    uart_put_hex32(mepc);
    uart_puts("\n  mtval  = ");
    uart_put_hex32(mtval);
    uart_puts("\n  irq#   = ");
    /* For interrupts, low bits of mcause are the IRQ number. */
    uart_put_u32(mcause & 0x7fffffffu);
    uart_puts("\nhalted.\n");
}

/* ============================================================
 * Tiny string utilities.
 * ============================================================ */
static int str_eq(const char *a, const char *b)
{
    while (*a && *b)
    {
        if (*a++ != *b++)
        {
            return 0;
        }
    }
    return *a == *b;
}

/* Parse leading non-negative decimal. Returns 0 on empty / non-digit input. */
static uint32_t parse_u32(const char *s)
{
    uint32_t v = 0;
    while (*s >= '0' && *s <= '9')
    {
        v = v * 10 + (uint32_t)(*s++ - '0');
    }
    return v;
}

/* ============================================================
 * Line-edited input (single line, supports backspace).
 * ============================================================ */
#define LINEBUF_LEN 64

static void readline(char *buf, int max)
{
    int n = 0;
    for (;;)
    {
        char c = uart_getc();
        if (c == '\r' || c == '\n')
        {
            uart_putc('\n');
            buf[n] = '\0';
            return;
        }
        if (c == 0x7f || c == 0x08)
        {
            if (n > 0)
            {
                --n;
                uart_puts("\b \b");
            }
            continue;
        }
        if (c == 0x03)
        { /* Ctrl-C — abandon line */
            uart_puts("^C\n");
            buf[0] = '\0';
            return;
        }
        if (n < max - 1 && c >= 0x20 && c < 0x7f)
        {
            buf[n++] = c;
            uart_putc(c);
        }
    }
}

/* Split `line` in-place into argv[]. Returns argc. */
static int tokenize(char *line, char *argv[], int max_argv)
{
    int argc = 0;
    char *p = line;
    while (*p && argc < max_argv)
    {
        while (*p == ' ' || *p == '\t')
        {
            *p++ = '\0';
        }
        if (!*p)
        {
            break;
        }
        argv[argc++] = p;
        while (*p && *p != ' ' && *p != '\t')
        {
            ++p;
        }
    }
    return argc;
}

/* ============================================================
 * App: banner.
 * ============================================================ */
static void app_banner(void)
{
    uart_puts("\n");
    uart_puts("\033[1m        __   _ __      _  __\033[0m\n");
    uart_puts("\033[1m       / /  (_) /____ | |/_/\033[0m\n");
    uart_puts("\033[1m      / /__/ / __/ -_)>  <\033[0m\n");
    uart_puts("\033[1m     /____/_/\\__/\\__/_/|_|\033[0m\n");
    uart_puts("\033[1m   Raptor on Tang Mega 138K Pro\033[0m\n");
    uart_puts("\n");
}

/* ============================================================
 * App: info.
 * ============================================================ */
extern char _sdata[], _edata[], _sbss[], _ebss[], _stack_top[];

static void app_info(void)
{
    uart_puts("Raptor RISC-V on Tang Mega 138K Pro\n");
    uart_puts("Built     : " __DATE__ " " __TIME__ "\n");
    uart_puts("ISA       : rv32imac_zicsr (FPGA build)\n");
    uart_puts("ROM base  : 0x20000000  size 32 KB\n");
    uart_puts("SRAM base : 0x0f000000  size  8 KB\n");
    uart_puts("UART base : 0xf0001800  (LiteX liteuart)\n");
    uart_puts(".data     : ");
    uart_put_hex32((uint32_t)(uintptr_t)_sdata);
    uart_puts(" - ");
    uart_put_hex32((uint32_t)(uintptr_t)_edata);
    uart_puts("\n.bss      : ");
    uart_put_hex32((uint32_t)(uintptr_t)_sbss);
    uart_puts(" - ");
    uart_put_hex32((uint32_t)(uintptr_t)_ebss);
    uart_puts("\nstack top : ");
    uart_put_hex32((uint32_t)(uintptr_t)_stack_top);
    uart_puts("\ncycle now : ");
    uart_put_hex32(rdcycle32());
    uart_puts("\n");
}

/* ============================================================
 * App: cycles — sanity-check rdcycle monotonic.
 * ============================================================ */
static void app_cycles(void)
{
    uint32_t c0 = rdcycle32();
    busy_loop(10000);
    uint32_t c1 = rdcycle32();
    uart_puts("rdcycle delta over 10000-iter busy loop = ");
    uart_put_u32(c1 - c0);
    uart_puts(" (");
    uart_put_hex32(c1 - c0);
    uart_puts(")\n");
}

/* ============================================================
 * App: primes (Sieve of Eratosthenes — small, on stack).
 * ============================================================ */
static void app_primes(uint32_t limit)
{
    /* Cap so the sieve fits comfortably in the 8 KB SRAM (sieve sits on the
     * stack at 1 byte per slot; 4096 leaves ~4 KB of headroom for everything
     * else). */
    if (limit < 2)
    {
        limit = 2;
    }
    if (limit > 4096)
    {
        limit = 4096;
    }
    uint8_t sieve[4097];
    for (uint32_t i = 0; i <= limit; ++i)
    {
        sieve[i] = 1;
    }
    sieve[0] = sieve[1] = 0;
    for (uint32_t i = 2; i * i <= limit; ++i)
    {
        if (sieve[i])
        {
            for (uint32_t j = i * i; j <= limit; j += i)
            {
                sieve[j] = 0;
            }
        }
    }
    uint32_t count = 0;
    uint32_t c0 = rdcycle32();
    for (uint32_t i = 2; i <= limit; ++i)
    {
        if (sieve[i])
        {
            uart_put_u32(i);
            uart_putc(' ');
            ++count;
        }
    }
    uint32_t c1 = rdcycle32();
    uart_puts("\n[");
    uart_put_u32(count);
    uart_puts(" primes <= ");
    uart_put_u32(limit);
    uart_puts(", ");
    uart_put_u32(c1 - c0);
    uart_puts(" cycles]\n");
}

/* ============================================================
 * App: fib.
 * ============================================================ */
static void app_fib(uint32_t n)
{
    if (n == 0)
    {
        n = 1;
    }
    if (n > 47)
    {
        n = 47; /* avoid uint32 overflow */
    }
    uint32_t a = 0, b = 1;
    for (uint32_t i = 0; i < n; ++i)
    {
        uart_put_u32(a);
        uart_putc(' ');
        uint32_t t = a + b;
        a = b;
        b = t;
    }
    uart_puts("\n");
}

/* ============================================================
 * App: memtest — pattern read/write on SRAM scratch.
 * Uses the unused tail of SRAM (between _ebss and stack) to avoid clobbering
 * live state. Conservative window size to leave plenty of stack headroom.
 * ============================================================ */
static void app_memtest(void)
{
    /* Carve a 1 KB window starting just above _ebss; bail out if it would
     * encroach on the lower 4 KB reserved for the stack. */
    uintptr_t base = (uintptr_t)_ebss;
    base = (base + 15) & ~(uintptr_t)15;
    uintptr_t top = (uintptr_t)_stack_top - 4096;
    if (base + 1024 > top)
    {
        uart_puts("memtest: not enough free SRAM, aborting\n");
        return;
    }
    volatile uint32_t *p = (volatile uint32_t *)base;
    uint32_t n = 1024 / 4;

    uart_puts("memtest scratch ");
    uart_put_hex32((uint32_t)base);
    uart_puts(" .. ");
    uart_put_hex32((uint32_t)(base + 1024));
    uart_puts("\n");

    static const uint32_t pats[] = {0x00000000, 0xffffffff, 0xa5a5a5a5,
                                    0x5a5a5a5a, 0xdeadbeef, 0xcafebabe};
    int errs = 0;
    for (size_t pi = 0; pi < sizeof(pats) / sizeof(pats[0]); ++pi)
    {
        for (uint32_t i = 0; i < n; ++i)
        {
            p[i] = pats[pi] ^ i;
        }
        for (uint32_t i = 0; i < n; ++i)
        {
            uint32_t got = p[i];
            if (got != (pats[pi] ^ i))
            {
                ++errs;
                if (errs <= 4)
                {
                    uart_puts(" mismatch @");
                    uart_put_hex32((uint32_t)(uintptr_t)&p[i]);
                    uart_puts(" exp ");
                    uart_put_hex32(pats[pi] ^ i);
                    uart_puts(" got ");
                    uart_put_hex32(got);
                    uart_puts("\n");
                }
            }
        }
        uart_putc('.');
    }
    uart_puts("\n");
    if (errs == 0)
    {
        uart_puts("memtest: PASS\n");
    }
    else
    {
        uart_puts("memtest: FAIL, errors=");
        uart_put_u32((uint32_t)errs);
        uart_puts("\n");
    }
}

/* ============================================================
 * App: mandelbrot — ASCII, 16.16 fixed-point.
 * ============================================================ */
static void app_mandelbrot(void)
{
    enum
    {
        W = 78,
        H = 28
    };
    static const char shades[] = " .:-=+*#%@";
    const int32_t ONE = 1 << 16;
    const int32_t FOUR = 4 << 16;

    /* viewport: x in [-2.0, 1.0], y in [-1.0, 1.0]. Pre-compute per-pixel
     * step as a single 32-bit divide so the inner loop is just addition
     * (avoids pulling __divdi3 / __moddi3 from libgcc). */
    int32_t xmin = -2 * ONE;
    int32_t ymin = -1 * ONE;
    int32_t xstep = (3 * ONE) / W;
    int32_t ystep = (2 * ONE) / H;
    const int32_t maxit = 32;

    for (int py = 0; py < H; ++py)
    {
        int32_t y0 = ymin + ystep * py;
        for (int px = 0; px < W; ++px)
        {
            int32_t x0 = xmin + xstep * px;
            int32_t x = 0, y = 0;
            int32_t i = 0;
            for (; i < maxit; ++i)
            {
                int32_t x2 = (int32_t)(((int64_t)x * x) >> 16);
                int32_t y2 = (int32_t)(((int64_t)y * y) >> 16);
                if (x2 + y2 > FOUR)
                {
                    break;
                }
                int32_t xy = (int32_t)(((int64_t)x * y) >> 16);
                x = x2 - y2 + x0;
                y = (xy << 1) + y0;
            }
            if (i == maxit)
            {
                uart_putc(' ');
            }
            else
            {
                uart_putc(shades[i % (sizeof(shades) - 1)]);
            }
        }
        uart_putc('\n');
    }
}

/* ============================================================
 * App: donut — direct port of Andy Sloane's a1k0n donut.
 *
 * Algorithm matches abstract-machine/.../demo/src/donut/donut.c, which is
 * the standard 1024-scale fixed-point version (no sin/cos table, no
 * libgcc divides). Buffer layout is the original 80x22 = 1760 cells; we
 * print the first 50 columns of each row (matches the reference's
 * `if (x < 50)` cull) so the frame fits a typical 80-col terminal even
 * after CRLF expansion.
 *
 * Stack budget: 1760 + 1760 = ~3.5 KB on top of normal frames. SRAM is
 * 8 KB so this leaves enough headroom; allocate the buffers on the
 * stack so they don't permanently reserve .bss.
 *
 * The R(mul,shift,c,s) macro is the original incremental rotator: it
 * rotates (c,s) by an angle whose tan ≈ mul/2^shift, then renormalises
 * back onto the unit circle (radius 1024) using a Taylor approximation
 * to compensate for fixed-point drift.
 *
 * Press any key to abort early; otherwise stops after FRAMES frames.
 * ============================================================ */

#define DONUT_R(mul, shift, x, y)                                              \
    do                                                                         \
    {                                                                          \
        _ = x;                                                                 \
        x -= (mul) * (y) >> (shift);                                           \
        y += (mul) * _ >> (shift);                                             \
        _ = (3145728 - (x) * (x) - (y) * (y)) >> 11;                           \
        x = (x) * _ >> 10;                                                     \
        y = (y) * _ >> 10;                                                     \
    } while (0)

static void app_donut(void)
{
    enum
    {
        SCREEN_W = 80, /* buffer stride; matches reference */
        SCREEN_H = 22,
        VIS_W    = 50, /* columns actually transmitted per row */
        FRAMES   = 600
    };
    static const char shades[] = ".,-~:;=!*#$@";

    char        b[SCREEN_H * SCREEN_W];
    signed char z[SCREEN_H * SCREEN_W];
    int         sA = 1024, cA = 0, sB = 1024, cB = 0, _;

    uart_puts("\033[2J\033[?25l"); /* clear + hide cursor */

    /* Drain any RX bytes left over from the prompt's "donut\r\n" — many
     * terminals send CRLF on Enter, and `readline` returns on the first
     * CR/LF byte while the partner is still in the FIFO. Without this drain
     * the very first uart_getc_nonblock() below sees that stale byte and
     * exits the animation immediately (the bug that produced an empty
     * screen + "[donut done]"). */
    while (uart_getc_nonblock() >= 0)
    {
    }

    for (int frame = 0; frame < FRAMES; ++frame)
    {
        int kc = uart_getc_nonblock();
        /* Ignore stray CR/LF/NUL so escape-sequence prefixes from arrow keys
         * etc. don't terminate the demo prematurely. */
        if (kc >= 0 && kc != '\r' && kc != '\n' && kc != 0)
        {
            break;
        }

        /* Reset frame buffers. */
        for (int k = 0; k < SCREEN_H * SCREEN_W; ++k)
        {
            b[k] = ' ';
            z[k] = 127;
        }

        int sj = 0, cj = 1024;
        for (int j = 0; j < 90; ++j)
        {
            int si = 0, ci = 1024;
            for (int i = 0; i < 324; ++i)
            {
                int R1 = 1, R2 = 2048, K2 = 5120 * 1024;

                int x0 = R1 * cj + R2;
                int x1 = ci * x0 >> 10;
                int x2 = cA * sj >> 10;
                int x3 = si * x0 >> 10;
                int x4 = R1 * x2 - (sA * x3 >> 10);
                int x5 = sA * sj >> 10;
                int x6 = K2 + R1 * 1024 * x5 + cA * x3;
                int x7 = cj * si >> 10;
                int x  = 25 + 30 * (cB * x1 - sB * x4) / x6;
                int y  = 12 + 15 * (cB * x4 + sB * x1) / x6;
                int N  = (((-cA * x7 - cB * ((-sA * x7 >> 10) + x2) -
                           ci * (cj * sB >> 10)) >>
                          10) -
                         x5) >>
                        7;

                int         o  = x + SCREEN_W * y;
                signed char zz = (x6 - K2) >> 15;
                if (y > 0 && y < SCREEN_H && x > 0 && x < SCREEN_W &&
                    zz < z[o])
                {
                    z[o] = zz;
                    b[o] = shades[N > 0 ? (N < (int)sizeof(shades) - 1
                                               ? N
                                               : (int)sizeof(shades) - 2)
                                        : 0];
                }
                DONUT_R(5, 8, ci, si); /* rotate i */
            }
            DONUT_R(9, 7, cj, sj); /* rotate j */
        }
        DONUT_R(5, 7, cA, sA);
        DONUT_R(5, 8, cB, sB);

        /* Dump frame using absolute cursor positioning + erase-to-EOL.
         * A trailing '\n' on the last row would push the cursor below the
         * viewport and trigger scroll-up — that scrolls each previous frame
         * one line above the next, producing the "stacked donuts" you see
         * if you only home with \033[H. \033[r;1H places the cursor without
         * any side-effect, and \033[K wipes any leftover from a prior frame
         * that was wider on this row. */
        for (int y = 0; y < SCREEN_H; ++y)
        {
            const char *row = &b[y * SCREEN_W];
            /* "\033[<r>;1H" — rows are 1-based in ANSI/VT. */
            uart_puts("\033[");
            uart_put_u32((uint32_t)(y + 1));
            uart_puts(";1H");
            for (int x = 0; x < VIS_W; ++x)
            {
                uart_putc(row[x]);
            }
            uart_puts("\033[K"); /* erase to EOL */
        }
    }

    uart_puts("\033[?25h\033[");
    uart_put_u32(SCREEN_H + 1);
    uart_puts(";1H[donut done]\n");
}

#undef DONUT_R

/* ============================================================
 * App: coremark — explanatory stub.
 * ============================================================ */
static void app_coremark(void)
{
    uart_puts("CoreMark cannot run from this firmware image.\n");
    uart_puts("Reasons:\n");
    uart_puts("  * 8 KB SRAM is too small for CoreMark state + stack +\n");
    uart_puts("    printf buffers (>=12 KB typical).\n");
    uart_puts("  * The FPGA SoC has no integrated main_ram on this build\n");
    uart_puts("    (PnR-density-limited on the GW5AST-LV138).\n");
    uart_puts("\nTo benchmark CoreMark on the FPGA:\n");
    uart_puts("  1. Build with BOOT_MODE=bios and a main_ram region:\n");
    uart_puts("       make fpga-build BOOT_MODE=bios \\\n");
    uart_puts("            EXTRA_FLAGS='--integrated-main-ram-size=0x8000'\n");
    uart_puts("  2. Flash bitstream, then upload coremark.bin via\n");
    uart_puts("       litex_term --kernel=build/.../coremark.bin /dev/tty.*\n");
    uart_puts("  3. The LiteX BIOS `serialboot` jumps to 0x80000000.\n");
    uart_puts("\nIn-sim CoreMark is available today via:  make coremark\n");
}

/* ============================================================
 * App: rom-crc — compute CRC32 over the live ROM image.
 *
 * Streams every byte of [_srom, _erom) through a CRC32 (poly 0xEDB88320,
 * IEEE 802.3, init 0xffffffff, final XOR 0xffffffff — same as zlib /
 * `crc32` CLI / `litex.soc.software.crcfbigen`). Compare the printed
 * value against the host-side reference, e.g.
 *
 *   $ python3 -c 'import sys,zlib; \
 *       print(hex(zlib.crc32(open(sys.argv[1],"rb").read())))' \
 *       build/firmware/fpga/boot.bin
 *
 * If the FPGA's value diverges, BSRAM/AXI fetch is silently corrupting
 * ROM reads — the most likely culprit for the recurring "code at high
 * ROM addresses hangs" pattern.
 * ============================================================ */
extern char _srom[], _erom[];

static void app_rom_crc(void)
{
    uint32_t crc = 0xffffffffu;
    const volatile uint8_t *p = (const volatile uint8_t *)_srom;
    const volatile uint8_t *end = (const volatile uint8_t *)_erom;
    uint32_t bytes = (uint32_t)(uintptr_t)(end - p);

    uart_puts("rom-crc range = ");
    uart_put_hex32((uint32_t)(uintptr_t)p);
    uart_puts(" .. ");
    uart_put_hex32((uint32_t)(uintptr_t)end);
    uart_puts(" (");
    uart_put_u32(bytes);
    uart_puts(" bytes)\n");

    uint32_t c0 = rdcycle32();
    while (p < end)
    {
        crc ^= (uint32_t)*p++;
        for (int b = 0; b < 8; ++b)
        {
            uint32_t mask = -(crc & 1u);
            crc = (crc >> 1) ^ (0xedb88320u & mask);
        }
    }
    uint32_t c1 = rdcycle32();
    crc ^= 0xffffffffu;

    uart_puts("rom-crc value = ");
    uart_put_hex32(crc);
    uart_puts("  (");
    uart_put_u32(c1 - c0);
    uart_puts(" cycles)\n");
    uart_puts("compare with: python3 -c 'import sys,zlib;"
              "print(hex(zlib.crc32(open(sys.argv[1],\"rb\").read())))'"
              " build/firmware/fpga/boot.bin\n");
}

/* ============================================================
 * Shell.
 * ============================================================ */
static void app_help(void);

static void prompt(void) { uart_puts("\033[1;32mraptor>\033[0m "); }

static void shell(void)
{
    char line[LINEBUF_LEN];
    char *argv[8];
    for (;;)
    {
        prompt();
        readline(line, sizeof(line));
        int argc = tokenize(line, argv, 8);
        if (argc == 0)
        {
            continue;
        }
        const char *cmd = argv[0];

        /* Capture cycle/instret around dispatch. RV32 `cycle`/`instret` are
         * 32-bit shadows of the 64-bit mcycle/minstret; on a 27 MHz FPGA a
         * 32-bit counter wraps every ~159 s, so a single shell command
         * fits even for `donut`. The unsigned subtraction still yields the
         * correct delta across one wrap. */
        uint32_t c0 = rdcycle32();
        uint32_t i0 = rdinstret32();
        int      report_stats = 1;

        if (str_eq(cmd, "help") || str_eq(cmd, "?"))
        {
            app_help();
        }
        else if (str_eq(cmd, "info"))
        {
            app_info();
        }
        else if (str_eq(cmd, "banner"))
        {
            app_banner();
        }
        else if (str_eq(cmd, "hello"))
        {
            uart_puts("hello, world!\n");
        }
        else if (str_eq(cmd, "echo"))
        {
            for (int i = 1; i < argc; ++i)
            {
                uart_puts(argv[i]);
                if (i + 1 < argc)
                {
                    uart_putc(' ');
                }
            }
            uart_putc('\n');
        }
        else if (str_eq(cmd, "cycles"))
        {
            app_cycles();
        }
        else if (str_eq(cmd, "primes"))
        {
            uint32_t n = (argc > 1) ? parse_u32(argv[1]) : 200;
            app_primes(n);
        }
        else if (str_eq(cmd, "fib"))
        {
            uint32_t n = (argc > 1) ? parse_u32(argv[1]) : 24;
            app_fib(n);
        }
        else if (str_eq(cmd, "memtest"))
        {
            app_memtest();
        }
        else if (str_eq(cmd, "mandelbrot") || str_eq(cmd, "mandel"))
        {
            app_mandelbrot();
        }
        else if (str_eq(cmd, "donut"))
        {
            app_donut();
        }
        else if (str_eq(cmd, "coremark"))
        {
            app_coremark();
        }
        else if (str_eq(cmd, "rom-crc") || str_eq(cmd, "romcrc"))
        {
            app_rom_crc();
        }
        else if (str_eq(cmd, "clear") || str_eq(cmd, "cls"))
        {
            uart_puts("\033[2J\033[H");
            report_stats = 0; /* would clobber the cleared screen */
        }
        else if (str_eq(cmd, "reboot"))
        {
            reboot();
            report_stats = 0; /* unreachable */
        }
        else
        {
            uart_puts("unknown command: ");
            uart_puts(cmd);
            uart_puts("  (try `help`)\n");
            report_stats = 0;
        }

        if (report_stats)
        {
            uint32_t cycles  = rdcycle32() - c0;
            uint32_t instret = rdinstret32() - i0;
            uart_puts("\033[2m[cycles=");
            uart_put_u32(cycles);
            uart_puts(" instret=");
            uart_put_u32(instret);
            uart_puts(" IPC=");
            uart_put_ratio_q2(instret, cycles);
            uart_puts("]\033[0m\n");
        }
    }
}

static void app_help(void)
{
    uart_puts("Built-in commands:\n");
    uart_puts("  help          this message\n");
    uart_puts("  info          SoC + build + memory map info\n");
    uart_puts("  banner        ASCII-art logo\n");
    uart_puts("  hello         hello world\n");
    uart_puts("  echo ARG...   echo arguments\n");
    uart_puts("  cycles        rdcycle delta over a busy loop\n");
    uart_puts("  primes [N]    print primes <= N (default 200, max 4096)\n");
    uart_puts("  fib [N]       print first N Fibonacci numbers (default 24)\n");
    uart_puts("  memtest       pattern test on SRAM scratch region\n");
    uart_puts("  mandelbrot    78x28 ASCII Mandelbrot (fixed-point)\n");
    uart_puts("  donut         spinning ASCII donut (any key to stop)\n");
    uart_puts("  coremark      explain why CoreMark needs a different build\n");
    uart_puts("  rom-crc       CRC32 of live ROM image (compare to host CRC)\n");
    uart_puts("  clear         clear screen\n");
    uart_puts("  reboot        soft reset (jump to _start)\n");
}

/* ============================================================
 * Entry.
 * ============================================================ */
void main(unsigned long hartid)
{
    (void)hartid;
    app_banner();
    uart_puts(" Built: " __DATE__ " " __TIME__ "\n");
    uart_puts(" Type `help` for available commands.\n\n");
    shell();
}

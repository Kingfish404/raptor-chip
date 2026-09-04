#include <common.h>

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <termios.h>
#include <unistd.h>
#include <verilated.h>

#include <string>

// https://github.com/riscv-software-src/riscv-isa-sim/blob/master/riscv/ns16550.cc
#define UART_QUEUE_SIZE 64
#define UART_IRQ 10u

#define UART_RX 0 /* In:  Receive buffer */
#define UART_TX 0 /* Out: Transmit buffer */

#define UART_IER 1         /* Out: Interrupt Enable Register */
#define UART_IER_MSI 0x08  /* Enable Modem status interrupt */
#define UART_IER_RLSI 0x04 /* Enable receiver line status interrupt */
#define UART_IER_THRI 0x02 /* Enable Transmitter holding register int. */
#define UART_IER_RDI 0x01  /* Enable receiver data interrupt */

#define UART_IIR 2           /* In:  Interrupt ID Register */
#define UART_IIR_NO_INT 0x01 /* No interrupts pending */
#define UART_IIR_ID 0x0e     /* Mask for the interrupt ID */
#define UART_IIR_MSI 0x00    /* Modem status interrupt */
#define UART_IIR_THRI 0x02   /* Transmitter holding register empty */
#define UART_IIR_RDI 0x04    /* Receiver data interrupt */
#define UART_IIR_RLSI 0x06   /* Receiver line status interrupt */

#define UART_IIR_TYPE_BITS 0xc0

#define UART_FCR 2                /* Out: FIFO Control Register */
#define UART_FCR_ENABLE_FIFO 0x01 /* Enable the FIFO */
#define UART_FCR_CLEAR_RCVR 0x02  /* Clear the RCVR FIFO */
#define UART_FCR_CLEAR_XMIT 0x04  /* Clear the XMIT FIFO */
#define UART_FCR_DMA_SELECT 0x08  /* For DMA applications */

#define UART_LCR 3           /* Out: Line Control Register */
#define UART_LCR_DLAB 0x80   /* Divisor latch access bit */
#define UART_LCR_SBC 0x40    /* Set break control */
#define UART_LCR_SPAR 0x20   /* Stick parity (?) */
#define UART_LCR_EPAR 0x10   /* Even parity select */
#define UART_LCR_PARITY 0x08 /* Parity Enable */
#define UART_LCR_STOP 0x04   /* Stop bits: 0=1 bit, 1=2 bits */

#define UART_MCR 4         /* Out: Modem Control Register */
#define UART_MCR_LOOP 0x10 /* Enable loopback test mode */
#define UART_MCR_OUT2 0x08 /* Out2 complement */
#define UART_MCR_OUT1 0x04 /* Out1 complement */
#define UART_MCR_RTS 0x02  /* RTS complement */
#define UART_MCR_DTR 0x01  /* DTR complement */

#define UART_LSR 5                   /* In:  Line Status Register */
#define UART_LSR_FIFOE 0x80          /* Fifo error */
#define UART_LSR_TEMT 0x40           /* Transmitter empty */
#define UART_LSR_THRE 0x20           /* Transmit-hold-register empty */
#define UART_LSR_BI 0x10             /* Break interrupt indicator */
#define UART_LSR_FE 0x08             /* Frame error indicator */
#define UART_LSR_PE 0x04             /* Parity error indicator */
#define UART_LSR_OE 0x02             /* Overrun error indicator */
#define UART_LSR_DR 0x01             /* Receiver data ready */
#define UART_LSR_BRK_ERROR_BITS 0x1E /* BI, FE, PE, OE bits */

#define UART_MSR 6              /* In:  Modem Status Register */
#define UART_MSR_DCD 0x80       /* Data Carrier Detect */
#define UART_MSR_RI 0x40        /* Ring Indicator */
#define UART_MSR_DSR 0x20       /* Data Set Ready */
#define UART_MSR_CTS 0x10       /* Clear to Send */
#define UART_MSR_DDCD 0x08      /* Delta DCD */
#define UART_MSR_TERI 0x04      /* Trailing edge ring indicator */
#define UART_MSR_DDSR 0x02      /* Delta DSR */
#define UART_MSR_DCTS 0x01      /* Delta CTS */
#define UART_MSR_ANY_DELTA 0x0F /* Any of the delta bits! */

#define UART_SCR 7 /* I/O: Scratch Register */

static uint32_t fcr, lcr, mcr, ier, scr;
static uint32_t dll, dlm;
static uint8_t rx_buf[UART_QUEUE_SIZE];
static uint8_t rx_head, rx_tail, rx_count;
static bool tx_irq_pending;
static bool stdin_flags_saved;
static int stdin_saved_flags;
static bool stdin_termios_saved;
static struct termios stdin_saved_termios;
static bool stdin_cleanup_registered;
static int tty_input_fd = -1;
static bool tty_fallback_attempted;
static bool tty_termios_saved;
static struct termios tty_saved_termios;
static bool serial_lf_to_cr;
static std::string serial_exit_pattern;
static std::string serial_tx_window;

void nsim_plic_raise(uint32_t irq);
bool sdb_is_batch_mode();
extern NPCState npc;
extern VerilatedContext *contextp;

static void serial_restore_stdin()
{
    if (tty_input_fd >= 0)
    {
        if (tty_termios_saved)
            tcsetattr(tty_input_fd, TCSANOW, &tty_saved_termios);
        close(tty_input_fd);
        tty_input_fd = -1;
    }
    if (stdin_termios_saved)
        tcsetattr(STDIN_FILENO, TCSANOW, &stdin_saved_termios);
    if (stdin_flags_saved)
        fcntl(STDIN_FILENO, F_SETFL, stdin_saved_flags);
}

static void serial_signal_restore(int signo)
{
    serial_restore_stdin();
    signal(signo, SIG_DFL);
    raise(signo);
}

static void serial_register_cleanup()
{
    if (stdin_cleanup_registered)
        return;
    atexit(serial_restore_stdin);
    signal(SIGINT, serial_signal_restore);
    signal(SIGTERM, serial_signal_restore);
    signal(SIGHUP, serial_signal_restore);
    stdin_cleanup_registered = true;
}

static void serial_configure_stdin()
{
    serial_register_cleanup();

    int flags = fcntl(STDIN_FILENO, F_GETFL, 0);
    if (flags >= 0)
    {
        if (!stdin_flags_saved)
        {
            stdin_saved_flags = flags;
            stdin_flags_saved = true;
        }
        fcntl(STDIN_FILENO, F_SETFL, stdin_saved_flags | O_NONBLOCK);
    }

    if (!sdb_is_batch_mode() || !isatty(STDIN_FILENO))
        return;

    if (!stdin_termios_saved)
    {
        if (tcgetattr(STDIN_FILENO, &stdin_saved_termios) != 0)
            return;
        stdin_termios_saved = true;
    }

    struct termios term = stdin_saved_termios;
    term.c_lflag &= ~(ECHO | ICANON);
    term.c_cc[VMIN] = 0;
    term.c_cc[VTIME] = 0;
    tcsetattr(STDIN_FILENO, TCSANOW, &term);
}

static bool serial_read_host_byte(uint8_t *ch)
{
    for (;;)
    {
        int input_fd = tty_input_fd >= 0 ? tty_input_fd : STDIN_FILENO;
        ssize_t nread = read(input_fd, ch, 1);
        if (nread == 1)
        {
            if (serial_lf_to_cr && *ch == '\n')
                *ch = '\r';
            return true;
        }
        if (nread == 0)
        {
            if (input_fd == STDIN_FILENO && sdb_is_batch_mode()
                && !tty_fallback_attempted)
            {
                tty_fallback_attempted = true;
                tty_input_fd = open("/dev/tty", O_RDONLY | O_NONBLOCK | O_NOCTTY);
                if (tty_input_fd >= 0)
                {
                    pid_t foreground_pgrp = tcgetpgrp(tty_input_fd);
                    if (foreground_pgrp >= 0 && foreground_pgrp != getpgrp())
                    {
                        close(tty_input_fd);
                        tty_input_fd = -1;
                        Log("serial input: stdin reached EOF; /dev/tty belongs to foreground process group %d",
                            (int)foreground_pgrp);
                        return false;
                    }
                    struct termios term;
                    if (tcgetattr(tty_input_fd, &tty_saved_termios) == 0)
                    {
                        tty_termios_saved = true;
                        term = tty_saved_termios;
                        term.c_lflag &= ~(ECHO | ICANON);
                        term.c_cc[VMIN] = 0;
                        term.c_cc[VTIME] = 0;
                        tcsetattr(tty_input_fd, TCSANOW, &term);
                    }
                    Log("serial input: stdin reached EOF; continuing from /dev/tty");
                    continue;
                }
                Log("serial input: stdin reached EOF; /dev/tty unavailable (%s)",
                    strerror(errno));
            }
            return false;
        }
        if (errno == EINTR)
            continue;
        return false;
    }
}

void serial_set_lf_to_cr(bool enable)
{
    serial_lf_to_cr = enable;
}

void serial_set_exit_pattern(const char *pattern)
{
    serial_exit_pattern = pattern != nullptr ? pattern : "";
    serial_tx_window.clear();
}

static void serial_write_host_byte(uint8_t ch)
{
    if (fputc((int)ch, stderr) != EOF)
        fflush(stderr);

    if (serial_exit_pattern.empty() || npc.state != NPC_RUNNING)
        return;
    serial_tx_window.push_back((char)ch);
    if (serial_tx_window.size() > serial_exit_pattern.size())
        serial_tx_window.erase(0, serial_tx_window.size() - serial_exit_pattern.size());
    if (serial_tx_window == serial_exit_pattern)
    {
        Log("serial exit milestone reached: %s", serial_exit_pattern.c_str());
        contextp->gotFinish(true);
        npc.host_exit_ok = 1;
        npc.state = NPC_END;
    }
}

static void serial_update_irq()
{
    if ((ier & UART_IER_RDI) && rx_count != 0)
        nsim_plic_raise(UART_IRQ);
    if ((ier & UART_IER_THRI) && tx_irq_pending)
        nsim_plic_raise(UART_IRQ);
}

static void rx_push(uint8_t ch)
{
    if (rx_count == UART_QUEUE_SIZE)
        return;
    rx_buf[rx_tail] = ch;
    rx_tail = (rx_tail + 1) % UART_QUEUE_SIZE;
    rx_count++;
}

static bool rx_pop(uint8_t *ch)
{
    if (rx_count == 0)
        return false;
    *ch = rx_buf[rx_head];
    rx_head = (rx_head + 1) % UART_QUEUE_SIZE;
    rx_count--;
    return true;
}

static void serial_poll_stdin()
{
    uint8_t ch;
    while (rx_count < UART_QUEUE_SIZE)
    {
        if (serial_read_host_byte(&ch))
        {
            rx_push(ch);
            serial_update_irq();
            continue;
        }
        if (errno == EAGAIN || errno == EWOULDBLOCK)
            return;
        return;
    }
}

void init_serial()
{
    fcr = 0;
    lcr = 0;
    mcr = UART_MCR_OUT2;
    ier = 0;
    scr = 0;
    dll = 0;
    dlm = 0;
    rx_head = 0;
    rx_tail = 0;
    rx_count = 0;
    tx_irq_pending = false;
    tty_fallback_attempted = false;
    tty_termios_saved = false;

    serial_configure_stdin();
}

void mmio_serial_handle(paddr_t offset, word_t wdata, bool is_write, word_t *data)
{
    uint8_t word_offset = offset & (sizeof(word_t) - 1);
    offset &= 0xff;
    uint32_t val = 0;
    if (is_write)
    {
        val = wdata & 0xff;
    }
    switch (offset)
    {
    case UART_TX:
        if (is_write)
        {
            if (lcr & UART_LCR_DLAB)
            {
                dll = val;
                break;
            }
            if (mcr & UART_MCR_LOOP)
            {
                break;
            }
            serial_write_host_byte((uint8_t)val);
            tx_irq_pending = true;
            serial_update_irq();
        }
        else
        {
            if (lcr & UART_LCR_DLAB)
            {
                val = dll;
            }
            else
            {
                uint8_t ch;
                serial_poll_stdin();
                val = rx_pop(&ch) ? ch : 0;
                serial_update_irq();
            }
        }
        break;
    case UART_IER:
        if (is_write)
        {
            if (lcr & UART_LCR_DLAB)
            {
                dlm = val;
            }
            else
            {
                ier = val;
                serial_update_irq();
            }
        }
        else
        {
            val = (lcr & UART_LCR_DLAB) ? dlm : ier;
        }
        break;
    case UART_IIR:
        if (is_write)
        {
            fcr = val;
        }
        else
        {
            serial_poll_stdin();
            if ((ier & UART_IER_RDI) && rx_count != 0)
            {
                val = UART_IIR_RDI;
            }
            else if ((ier & UART_IER_THRI) && tx_irq_pending)
            {
                val = UART_IIR_THRI;
                tx_irq_pending = false;
            }
            else
            {
                val = UART_IIR_NO_INT;
            }
            val |= (fcr & UART_FCR_ENABLE_FIFO) ? UART_IIR_TYPE_BITS : 0;
        }
        break;
    case UART_LCR:
        if (is_write)
        {
            lcr = val;
        }
        else
        {
            val = lcr;
        }
        break;
    case UART_MCR:
        if (is_write)
        {
            mcr = val;
        }
        else
        {
            val = mcr;
        }
        break;
    case UART_LSR:
        serial_poll_stdin();
        val = UART_LSR_TEMT | UART_LSR_THRE | (rx_count != 0 ? UART_LSR_DR : 0);
        break;
    case UART_MSR:
        val = UART_MSR_DCD | UART_MSR_DSR | UART_MSR_CTS;
        break;
    case UART_SCR:
        if (is_write)
        {
            scr = val;
        }
        else
        {
            val = scr;
        }
        break;
    default:
        break;
    }
    if (!is_write)
    {
        *data = word_t(val) << (word_offset * 8);
    }
}

void serial_tick()
{
    serial_poll_stdin();
    serial_update_irq();
}

unsigned serial_rx_pending()
{
    return rx_count;
}

const char *serial_input_source()
{
    if (tty_input_fd >= 0)
        return "tty";
    if (tty_fallback_attempted)
        return "none";
    return isatty(STDIN_FILENO) ? "stdin-tty" : "stdin-pipe";
}

// ----------------------------------------------------------------------------
// LiteX UART model (used by egos-2000 HARDWARE platform at 0xf000_1000).
// Register layout (from litex/soc/cores/uart.py and egos dev_tty.c):
//   0x00 RXTX     : R=pop RX byte / W=push TX byte
//   0x04 TXFULL   : R=1 if TX FIFO full
//   0x08 RXEMPTY  : R=1 if RX FIFO empty
//   0x0c EV_STATUS: R=event status (unused)
//   0x10 EV_PENDING: R/W1C event pending (bit0=tx, bit1=rx)
//   0x14 EV_ENABLE: R/W event enable
// We model a single-byte RX latch fed lazily from stdin; TX writes go to host
// stderr through the existing helpers. EVPEND/EVENABLE are stored but do not
// drive any IRQ in this minimal model.
// ----------------------------------------------------------------------------

static uint8_t litex_uart_rx_byte;
static bool    litex_uart_rx_valid;
static uint8_t litex_uart_ev_pending;
static uint8_t litex_uart_ev_enable;
static bool    litex_uart_inited;

static void litex_uart_refill_rx()
{
    if (litex_uart_rx_valid)
        return;
    // Pop from the shared NS16550 stdin queue so serial_tick()'s periodic
    // drain (which fills `rx_buf`) is visible here.  Without this, bytes
    // typed by the user (or piped via stdin) end up locked inside NS16550
    // and never reach egos's LiteX UART.
    serial_poll_stdin();
    uint8_t ch;
    if (rx_pop(&ch))
    {
        litex_uart_rx_byte = ch;
        litex_uart_rx_valid = true;
        litex_uart_ev_pending |= 0x2; // rx event pending
    }
}

void mmio_litex_uart_handle(paddr_t offset, word_t wdata, bool is_write, word_t *data)
{
    if (!litex_uart_inited)
    {
        serial_configure_stdin();
        litex_uart_inited = true;
    }
    uint8_t word_offset = offset & (sizeof(word_t) - 1);
    offset &= 0xff;
    uint32_t val = 0;
    uint8_t  wval = is_write ? (uint8_t)(wdata & 0xff) : 0;
    switch (offset & ~0x3u)
    {
    case 0x00: // RXTX
        if (is_write)
        {
            serial_write_host_byte(wval);
            litex_uart_ev_pending |= 0x1; // tx event pending
        }
        else
        {
            litex_uart_refill_rx();
            if (litex_uart_rx_valid)
            {
                val = litex_uart_rx_byte;
                litex_uart_rx_valid = false;
            }
        }
        break;
    case 0x04: // TXFULL
        val = 0;
        break;
    case 0x08: // RXEMPTY
        litex_uart_refill_rx();
        val = litex_uart_rx_valid ? 0 : 1;
        break;
    case 0x0c: // EV_STATUS
        val = (litex_uart_rx_valid ? 0x2 : 0) | 0x1; // tx always ready
        break;
    case 0x10: // EV_PENDING (W1C)
        if (is_write)
            litex_uart_ev_pending &= ~wval;
        else
            val = litex_uart_ev_pending;
        break;
    case 0x14: // EV_ENABLE
        if (is_write)
            litex_uart_ev_enable = wval;
        else
            val = litex_uart_ev_enable;
        break;
    default:
        break;
    }
    if (!is_write)
        *data = word_t(val) << (word_offset * 8);
}

void init_litex_uart()
{
    litex_uart_rx_byte    = 0;
    litex_uart_rx_valid   = false;
    litex_uart_ev_pending = 0;
    litex_uart_ev_enable  = 0;
    litex_uart_inited     = false;
}

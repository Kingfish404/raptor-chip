/***************************************************************************************
 * Copyright (c) 2014-2022 Zihao Yu, Nanjing University
 *
 * NEMU is licensed under Mulan PSL v2.
 * You can use this software according to the terms and conditions of the Mulan PSL v2.
 * You may obtain a copy of Mulan PSL v2 at:
 *          http://license.coscl.org.cn/MulanPSL2
 *
 * THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND,
 * EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT,
 * MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
 *
 * See the Mulan PSL v2 for more details.
 ***************************************************************************************/

#include <utils.h>
#include <device/map.h>

#ifndef CONFIG_TARGET_AM
#include <stdio.h>
#endif

#if defined(CONFIG_SERIAL_INPUT_FIFO) && !defined(CONFIG_TARGET_AM)
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <unistd.h>
#include <termios.h>
#define SERIAL_HOST_INPUT 1

static struct termios stdin_saved_termios;
static bool stdin_termios_saved = false;
static int stdin_saved_flags = 0;
static bool stdin_flags_saved = false;
static bool stdin_cleanup_registered = false;

static void serial_restore_stdin(void) {
  if (stdin_termios_saved) {
    tcsetattr(STDIN_FILENO, TCSANOW, &stdin_saved_termios);
  }
  if (stdin_flags_saved) {
    fcntl(STDIN_FILENO, F_SETFL, stdin_saved_flags);
  }
}

static void serial_signal_restore(int signo) {
  serial_restore_stdin();
  signal(signo, SIG_DFL);
  raise(signo);
}

static void serial_register_cleanup(void) {
  if (stdin_cleanup_registered) return;
  atexit(serial_restore_stdin);
  signal(SIGINT, serial_signal_restore);
  signal(SIGTERM, serial_signal_restore);
  signal(SIGHUP, serial_signal_restore);
  stdin_cleanup_registered = true;
}

static void serial_configure_stdin(void) {
  serial_register_cleanup();

  int flags = fcntl(STDIN_FILENO, F_GETFL, 0);
  if (flags >= 0) {
    if (!stdin_flags_saved) {
      stdin_saved_flags = flags;
      stdin_flags_saved = true;
    }
    fcntl(STDIN_FILENO, F_SETFL, stdin_saved_flags | O_NONBLOCK);
  }

  if (!isatty(STDIN_FILENO)) return;
  if (tcgetattr(STDIN_FILENO, &stdin_saved_termios) < 0) return;
  stdin_termios_saved = true;

  struct termios raw = stdin_saved_termios;
  raw.c_lflag &= ~(ICANON | ECHO);
  raw.c_cc[VMIN] = 0;
  raw.c_cc[VTIME] = 0;
  tcsetattr(STDIN_FILENO, TCSANOW, &raw);
}

#define SERIAL_RX_FIFO_SIZE 256
static uint8_t serial_rx_fifo[SERIAL_RX_FIFO_SIZE];
static int serial_rx_head = 0, serial_rx_tail = 0;
static bool serial_lf_to_cr = false;

void serial_set_lf_to_cr(bool enable) {
  serial_lf_to_cr = enable;
}

static inline int serial_rx_count(void) {
  return (serial_rx_tail - serial_rx_head + SERIAL_RX_FIFO_SIZE) % SERIAL_RX_FIFO_SIZE;
}

static inline int serial_rx_free(void) {
  return SERIAL_RX_FIFO_SIZE - 1 - serial_rx_count();
}

static void serial_rx_enqueue(uint8_t ch) {
  int next = (serial_rx_tail + 1) % SERIAL_RX_FIFO_SIZE;
  if (next == serial_rx_head) return; // full, drop
  serial_rx_fifo[serial_rx_tail] = ch;
  serial_rx_tail = next;
}

static int serial_rx_dequeue(void) {
  if (serial_rx_head == serial_rx_tail) return -1; // empty
  uint8_t ch = serial_rx_fifo[serial_rx_head];
  serial_rx_head = (serial_rx_head + 1) % SERIAL_RX_FIFO_SIZE;
  return ch;
}

static bool raw_term_inited = false;

static void serial_update_irq(void);

static void serial_ensure_host_stdin(void) {
  if (raw_term_inited) return;
  raw_term_inited = true;
  serial_configure_stdin();
}

void serial_poll_stdin(void) {
  serial_ensure_host_stdin();
  uint8_t buf[64];
  while (serial_rx_free() > 0) {
    size_t max_read = serial_rx_free() < (int)sizeof(buf)
        ? (size_t)serial_rx_free() : sizeof(buf);
    ssize_t n = read(STDIN_FILENO, buf, max_read);
    if (n > 0) {
      for (ssize_t i = 0; i < n; i++) {
        if (serial_lf_to_cr && buf[i] == '\n') {
          buf[i] = '\r';
        }
        serial_rx_enqueue(buf[i]);
      }
      serial_update_irq();
      continue;
    }
    if (n == 0) return;
    if (errno == EINTR) continue;
    if (errno == EAGAIN || errno == EWOULDBLOCK) return;
    return;
  }
}
#elif defined(CONFIG_SERIAL_INPUT_FIFO)
void serial_poll_stdin(void) {}
#ifndef CONFIG_TARGET_AM
void serial_set_lf_to_cr(bool enable) { (void)enable; }
#endif
#elif !defined(CONFIG_TARGET_AM)
void serial_set_lf_to_cr(bool enable) { (void)enable; }
#endif /* CONFIG_SERIAL_INPUT_FIFO */

/* http://en.wikibooks.org/wiki/Serial_Programming/8250_UART_Programming */
// NOTE: this is compatible to 16550

#define CH_OFFSET 0
#define SOC_DL2_OFFSET 1
#define SOC_LCR_OFFSET 3
#define SOC_LSR_OFFSET 5

static uint8_t *serial_base = NULL;
static uint8_t *serial_us16550_base = NULL;

static void serial_putc(uint8_t ch)
{
#ifdef CONFIG_TARGET_AM
  putch((char)ch);
#else
  if (fputc((int)ch, stderr) != EOF) {
    fflush(stderr);
  }
#endif
}

__attribute__((__unused__)) static void serial_io_handler(uint32_t offset, int len, bool is_write)
{
  assert(len == 1);
  switch (offset)
  {
  /* We bind the serial port with the host stderr in NEMU. */
  case CH_OFFSET:
    if (is_write)
      serial_putc(serial_base[0]);
    else
      panic("do not support read");
    break;
  case SOC_DL2_OFFSET:
  case SOC_LCR_OFFSET:
  case SOC_LSR_OFFSET:
    if (!is_write)
      serial_base[5] = (0x1 << 5);
    break;
  default:
    panic("do not support offset = %d", offset);
  }
}

// https://github.com/riscv-software-src/riscv-isa-sim/blob/master/riscv/ns16550.cc
#define UART_QUEUE_SIZE 64
// PLIC source raised by this ns16550 model. Linux derives its handler from
// the DTB (`ns16550@10000000 { interrupts = <N>; }` in
// nemu/src/memory/rom/spike-rv*ima*.dts) so the value here MUST match the
// DTB used by the workload, otherwise RX IRQs are silently dropped and
// tinysh appears unresponsive. xv6/egos poll LSR.DR and don't care.
// Configurable via Kconfig (`CONFIG_SERIAL_PLIC_IRQ`) so different
// defconfigs (Linux vs. tinyos vs. egos) can pick a non-colliding source.
#define UART_IRQ CONFIG_SERIAL_PLIC_IRQ

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
static bool tx_irq_pending;

extern void plic_raise_irq(int irq);

static void serial_update_irq(void)
{
#ifdef SERIAL_HOST_INPUT
  if ((ier & UART_IER_RDI) && serial_rx_count() > 0)
    plic_raise_irq(UART_IRQ);
#endif
  if ((ier & UART_IER_THRI) && tx_irq_pending)
    plic_raise_irq(UART_IRQ);
}

__attribute__((__unused__)) static void serial_io_handler_ns16550(uint32_t offset, int len, bool is_write)
{
  // printf("offset = %d, len = %d, is_write = %d, serial_base[0] = %d, serial_base[1] = %d\n",
  //        offset, len, is_write, serial_us16550_base[0], serial_us16550_base[1]);
  uint32_t val = serial_us16550_base[offset];
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
      serial_putc((uint8_t)val);
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
#ifdef SERIAL_HOST_INPUT
  serial_poll_stdin();
        int ch = serial_rx_dequeue();
        val = (ch >= 0) ? (uint8_t)ch : 0;
#else
        val = 0;
#endif
      }
    }
    break;
  case UART_IER:
    if (is_write)
    {
      if (!(lcr & UART_LCR_DLAB))
      {
        ier = val & 0x0f;
        serial_update_irq();
      }
      else
      {
        dlm = val;
      }
    }
    else
    {
      if (lcr & UART_LCR_DLAB)
      {
        val = dlm;
      }
      else
      {
        val = ier;
      }
    }
    break;
  case (UART_IIR | UART_FCR):
    if (is_write)
    {
      fcr = val;
    }
    else
    {
      // Compute IIR dynamically based on UART state
      uint8_t iir_type = (fcr & UART_FCR_ENABLE_FIFO) ? UART_IIR_TYPE_BITS : 0;
#ifdef SERIAL_HOST_INPUT
  serial_poll_stdin();
      if ((ier & UART_IER_RDI) && serial_rx_count() > 0)
        val = UART_IIR_RDI | iir_type;
      else
#endif
      if ((ier & UART_IER_THRI) && tx_irq_pending)
      {
        val = UART_IIR_THRI | iir_type;
        tx_irq_pending = false;
      }
      else
        val = UART_IIR_NO_INT | iir_type;
    }
    break;
  case UART_LCR:
    if (is_write)
    {
      lcr = val;
    }
    break;
  case UART_MCR:
    if (is_write)
    {
      mcr = val;
    }
    break;
  case UART_LSR:
    if (!is_write)
    {
      val = UART_LSR_TEMT | UART_LSR_THRE;
#ifdef SERIAL_HOST_INPUT
  serial_poll_stdin();
      if (serial_rx_count() > 0)
        val |= UART_LSR_DR;
#endif
    }
    break;
  case UART_MSR:
    break;
  case UART_SCR:
    if (is_write)
    {
      scr = val;
    }
    break;
  default:
    break;
  }
  serial_us16550_base[offset] = val;
}

void init_serial()
{
  serial_base = new_space(8);
  memset(serial_base, 0, 8);
  serial_us16550_base = new_space(0x100);
  memset(serial_us16550_base, 0, 0x100);
  serial_us16550_base[UART_IIR] = UART_IIR_NO_INT;
  serial_us16550_base[UART_LSR] = UART_LSR_TEMT | UART_LSR_THRE;
  serial_us16550_base[UART_MSR] = UART_MSR_DCD | UART_MSR_DSR | UART_MSR_CTS;
  serial_us16550_base[UART_MCR] = UART_MCR_OUT2;
  tx_irq_pending = false;
#ifdef CONFIG_HAS_PORT_IO
  add_pio_map("serial", CONFIG_SERIAL_PORT, serial_base, 8, serial_io_handler);
#else
  add_mmio_map("serial", CONFIG_SERIAL_MMIO, serial_base, 8, serial_io_handler);
  // https://github.com/riscv-software-src/riscv-isa-sim/blob/master/riscv/platform.h
  // https://github.com/riscv-software-src/riscv-isa-sim/blob/master/riscv/ns16550.cc
  add_mmio_map("serial_ns16550", CONFIG_SERIAL_MMIO_US16550, serial_us16550_base, 0x100, serial_io_handler_ns16550);
#endif

  // Raw terminal mode is deferred to first serial_poll_stdin() call,
  // so SDB readline works in non-batch mode.
}

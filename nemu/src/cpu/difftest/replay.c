#include <cpu/replay.h>

#ifdef NEMU_HAS_REPLAY
#include <cpu/cpu.h>
#include <cpu/diffjournal.h>
#include <cpu/multidiff.h>
#include <cpu/thread.h>
#include <difftest-journal.h>
#include <difftest-replay.h>
#include <isa.h>
#include <memory/paddr.h>
#include <utils.h>
#include <pthread.h>
#include <setjmp.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

typedef struct {
  pthread_t thread;
  unsigned hart;
  bool executing;
  uint64_t retired;
  CPU_state *live;
  NemuDiffState expected;
} ReplayHart;

static ReplayHart harts[NEMU_DIFF_MULTI_HARTS];
static pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t changed = PTHREAD_COND_INITIALIZER;
static FILE *input;
static char input_buffer[NEMU_JOURNAL_BUFFER_BYTES];
static NemuJournalHeader machine;
static NemuJournalRecord event;
static uint64_t payload[4 + 2 * NEMU_JOURNAL_STATE_WORDS];
static uint64_t sequence;
static uint64_t consumed = 64;
static uint64_t interleaved;
static uint64_t interrupts;
static uint64_t clocks;
static uint64_t io_requests;
static uint64_t last_clock;
static uint32_t msip[NEMU_DIFF_MULTI_HARTS];
static uint64_t plic_sources;
static uint32_t plic_priority[33];
static uint32_t plic_pending[2];
static uint32_t plic_enable[2 * NEMU_DIFF_MULTI_HARTS][2];
static uint32_t plic_threshold[2 * NEMU_DIFF_MULTI_HARTS];
static uint8_t uart_registers[8] = {0, 0, 1, 0, 8, 0x60, 0xb0, 0};
static uint8_t uart_fifo[255];
static unsigned uart_count, uart_head;
static uint8_t uart_ier, uart_fcr, uart_lcr, uart_mcr, uart_dll, uart_dlm;
static bool uart_tx_pending;
static uint64_t uart_rx, uart_irqs, uart_tx;
static uint64_t dma_reads, dma_writes, dma_bytes, rng_inputs, rng_irqs;
static uint64_t net_rx, net_tx, net_irqs, net_rx_bytes, net_tx_bytes, net_rx_drops;
static uint64_t block_reads, block_writes, block_bytes, block_irqs, block_image_size, block_pages;
static uint8_t *block_disk;
static struct {
  uint32_t feature_select, driver_select, driver_features[2], queue_select, size, ready, status, irq;
  uint64_t descriptors, available, used;
  uint16_t consumed;
} block;
typedef struct {
  uint32_t size, ready;
  uint64_t descriptors, available, used;
  uint16_t consumed;
} ReplayNetQueue;
static ReplayNetQueue net_queues[2];
static uint32_t net_features_select, net_driver_select, net_driver_features[2];
static uint32_t net_queue_select, net_status, net_interrupt_status;
static void net_receive(void);
static uint32_t rng_registers[43], rng_driver_features[2];
static uint16_t rng_available_index;
static uint64_t last_access_instruction;
static int last_access_hart = -1;
static unsigned maximum_active;
static unsigned ready;
static unsigned endings;
static int owner = -1;
static bool claimed, active, started, failed, complete;
static NEMU_TLS ReplayHart *current;
static NEMU_TLS unsigned bus_depth;
static NEMU_TLS jmp_buf escape;

static void check_thread(int result)
{
  if (result) {
    fprintf(stderr, "NEMU replay pthread failure: %s\n", strerror(result));
    abort();
  }
}

static void fail(const char *reason)
{
  if (!failed)
    fprintf(stderr, "NEMU_REPLAY_FAIL event=%" PRIu64 " hart=%" PRIu64
            " instruction=%" PRIu64 " kind=%" PRIu64 " %s\n",
            event.sequence, event.hart, event.instruction, event.kind, reason);
  failed = true;
  check_thread(pthread_cond_broadcast(&changed));
}

static void reject(const char *reason)
{
  fail(reason);
  nemu_longjmp(escape, 1);
}

static bool next_event(void)
{
  if (fread(&event, sizeof(event), 1, input) != 1 ||
      event.sequence != sequence || event.hart >= machine.harts ||
      event.instruction != harts[event.hart].retired || event.length > sizeof(payload) ||
      event.kind < JOURNAL_MEMORY || event.kind > (nemu_md_block ? JOURNAL_BLOCK_IRQ : nemu_md_net ? JOURNAL_NET_RX_RESULT : nemu_md_rng ? JOURNAL_RNG_IRQ : nemu_md_uart ? JOURNAL_UART_TX :
          (nemu_md_plic ? JOURNAL_PLIC_SOURCE : (nemu_md_clint ? JOURNAL_IO_REQUEST :
          (nemu_md_interrupts ? JOURNAL_INTERRUPT : JOURNAL_COMPLETE)))) ||
      (owner != -1 && event.hart != (unsigned)owner)) {
    fail("truncated or invalid event header");
    return false;
  }
  sequence++;
  if (event.length && fread(payload, event.length, 1, input) != 1) {
    fail("truncated event payload");
    return false;
  }
  if (event.length + sizeof(event) > UINT64_MAX - consumed) {
    fail("stream byte counter overflow");
    return false;
  }
  consumed += sizeof(event) + event.length;
  if (event.kind == JOURNAL_COMPLETE) {
    if (event.length != 48 || payload[0] != NEMU_END || payload[1] || owner != -1 || endings != 1) {
      fail("invalid completion");
      return false;
    }
    for (unsigned hart = 0; hart < NEMU_DIFF_MULTI_HARTS; hart++) {
      if (payload[2 + hart] != harts[hart].retired || harts[hart].executing ||
          (hart < machine.harts && !harts[hart].retired)) {
        fail("incomplete hart or retirement totals");
        return false;
      }
    }
    if (fgetc(input) != EOF || ferror(input)) {
      fail("trailing data or read error");
      return false;
    }
    complete = true;
  }
  if (complete || !current || event.hart != current->hart)
    check_thread(pthread_cond_broadcast(&changed));
  return true;
}

static bool await_hart(void)
{
  while (!failed && !complete && event.hart != current->hart)
    check_thread(pthread_cond_wait(&changed, &mutex));
  if (failed) nemu_longjmp(escape, 1);
  return !complete;
}

static void expect(unsigned kind, size_t length)
{
  if (!await_hart() || event.kind != kind || event.length != length)
    reject("unexpected operation or payload size");
}

static void advance(void)
{
  if (!next_event()) nemu_longjmp(escape, 1);
}

void nemu_replay_lock(void)
{
  if (!active) return;
  if (bus_depth++ == 0 && machine.threaded) {
    expect(JOURNAL_LOCK, 0);
    if (owner != -1) reject("nested outer bus acquisition");
    owner = current->hart;
    advance();
  }
}

void nemu_replay_unlock(void)
{
  if (!active) return;
  if (!bus_depth) reject("bus unlock without acquisition");
  if (--bus_depth == 0 && machine.threaded) {
    expect(JOURNAL_UNLOCK, 0);
    if (owner != (int)current->hart) reject("bus ownership mismatch");
    owner = -1;
    advance();
  }
}

void nemu_replay_unwind(void)
{
  if (active && bus_depth) {
    bus_depth = 1;
    nemu_replay_unlock();
  }
}

static void check_access(unsigned kind, paddr_t address, int size, bool write, word_t data)
{
  if (!current->executing || !bus_depth) reject("memory access outside instruction/bus scope");
  expect(kind, sizeof(NemuDiffMemory));
  NemuDiffMemory wanted;
  memcpy(&wanted, payload, sizeof(wanted));
  if ((size != 1 && size != 2 && size != 4 && size != 8) ||
      wanted.address != address || wanted.size != size || wanted.write != write)
    reject("memory address/width/direction mismatch before access");
  uint64_t mask = UINT64_MAX >> ((8 - size) * 8);
  if (wanted.data & ~mask) reject("memory value exceeds width");
  if (write && wanted.data != ((uint64_t)data & mask))
    reject("store value mismatch before reference write");
  if (kind == JOURNAL_IO_REQUEST && !write && wanted.data)
    reject("nonzero IO request load data");
}

void nemu_replay_access(paddr_t address, int size, bool write, word_t data)
{
  if (!active) return;
  bool io = nemu_md_clint_span(address, size, write) || nemu_md_plic_span(address, size) ||
      nemu_md_uart_span(address, size) || nemu_md_rng_span(address, size) || nemu_md_net_span(address, size, write) ||
      nemu_md_block_span(address, size);
  check_access(io ? JOURNAL_IO_REQUEST : JOURNAL_ACCESS, address, size, write, data);
  if (io) {
    io_requests++;
    advance();
  }
}

void nemu_journal_memory(paddr_t address, int size, bool write, word_t data)
{
  if (!active) return;
  check_access(JOURNAL_ACCESS, address, size, write, data);
  NemuDiffMemory wanted;
  memcpy(&wanted, payload, sizeof(wanted));
  if (wanted.data != ((uint64_t)data & (UINT64_MAX >> ((8 - size) * 8))))
    reject("independent reference load value mismatch");
  if (last_access_hart >= 0 && last_access_hart != (int)current->hart &&
      harts[last_access_hart].executing && harts[last_access_hart].retired == last_access_instruction)
    interleaved++;
  last_access_hart = current->hart;
  last_access_instruction = current->retired;
  advance();
}

static unsigned plic_pick(unsigned context)
{
  unsigned selected = 0;
  for (unsigned source = 32; source; source--) {
    uint32_t bit = UINT32_C(1) << (source % 32);
    if ((plic_pending[source / 32] & plic_enable[context][source / 32] & bit) &&
        plic_priority[source] > plic_threshold[context] &&
        (!selected || plic_priority[source] >= plic_priority[selected]))
      selected = source;
  }
  return selected;
}

static void plic_update(void)
{
  if (!nemu_md_plic) return;
  for (unsigned hart = 0; hart < machine.harts; hart++) {
    if (machine.threaded && hart != current->hart) continue;
    CPU_state *state = harts[hart].live;
    state->sr[CSR_MIP] = (state->sr[CSR_MIP] & ~(word_t)0x800) | (plic_pick(2 * hart) ? 0x800 : 0);
    state->seip = plic_pick(2 * hart + 1) != 0;
    state->sr[CSR_SIP] = riscv_hart_mip_value(state) & state->sr[CSR_MIDELEG] & (word_t)0x222;
  }
}

static void uart_signal(void)
{
  unsigned pulses = ((uart_ier & 1) && uart_count) + ((uart_ier & 2) && uart_tx_pending);
  for (unsigned pulse = 0; pulse < pulses; pulse++) {
    expect(JOURNAL_UART_IRQ, 16);
    if (payload[0] != NEMU_JOURNAL_UART_IRQ || payload[1] != current->executing)
      reject("derived UART IRQ mismatch");
    plic_pending[0] |= UINT32_C(1) << NEMU_JOURNAL_UART_IRQ;
    plic_update();
    uart_irqs++;
    advance();
  }
}

word_t nemu_replay_uart(paddr_t address, int size, bool write, word_t data)
{
  if (!active || !current->executing || !bus_depth || !nemu_md_uart_span(address, size))
    reject("invalid reference UART access");
  unsigned offset = address - NEMU_JOURNAL_UART_BASE;
  uint8_t value = write ? data : uart_registers[offset];
  if (write) {
    switch (offset) {
      case 0:
        if (uart_lcr & 0x80) uart_dll = value;
        else if (!(uart_mcr & 0x10)) {
          expect(JOURNAL_UART_TX, 16);
          if (payload[0] != value || payload[1] != 1) reject("UART output byte/context mismatch");
          uart_tx++;
          advance();
          uart_tx_pending = true;
          uart_signal();
        }
        break;
      case 1:
        if (uart_lcr & 0x80) uart_dlm = value;
        else {
          uart_ier = value & 15;
          uart_signal();
        }
        break;
      case 2: uart_fcr = value; break;
      case 3: uart_lcr = value; break;
      case 4: uart_mcr = value; break;
    }
  } else {
    switch (offset) {
      case 0:
        if (uart_lcr & 0x80) value = uart_dll;
        else if (uart_count) {
          value = uart_fifo[uart_head];
          uart_head = (uart_head + 1) % sizeof(uart_fifo);
          uart_count--;
        } else value = 0;
        break;
      case 1: value = uart_lcr & 0x80 ? uart_dlm : uart_ier; break;
      case 2:
        value = uart_fcr & 1 ? 0xc0 : 0;
        if ((uart_ier & 1) && uart_count) value |= 4;
        else if ((uart_ier & 2) && uart_tx_pending) {
          value |= 2;
          uart_tx_pending = false;
        } else value |= 1;
        break;
      case 5: value = 0x60 | (uart_count ? 1 : 0); break;
      case 6: value = 0xb0; break;
    }
  }
  uart_registers[offset] = value;
  return value;
}

word_t nemu_replay_plic(paddr_t address, int size, bool write, word_t data)
{
  if (!active || !current->executing || !bus_depth || !nemu_md_plic_span(address, size))
    reject("invalid reference PLIC access");
  uint64_t offset = address - NEMU_JOURNAL_PLIC_BASE;
  uint32_t *reg;
  if (offset < 33 * 4) {
    reg = &plic_priority[offset / 4];
  } else if (offset < 0x2000) {
    unsigned word = (offset - 0x1000) / 4;
    if (write) {
      plic_pending[word] |= (uint32_t)data & (word ? UINT32_MAX : ~UINT32_C(1));
      plic_update();
    }
    return plic_pending[word];
  } else if (offset < 0x200000) {
    reg = &plic_enable[(offset - 0x2000) / 0x80][((offset - 0x2000) % 0x80) / 4];
  } else {
    unsigned context = (offset - 0x200000) / 0x1000;
    if ((offset - 0x200000) % 0x1000 == 4) {
      unsigned selected = write ? 0 : plic_pick(context);
      if (selected) plic_pending[selected / 32] &= ~(UINT32_C(1) << (selected % 32));
      plic_update();
      return selected;
    }
    reg = &plic_threshold[context];
  }
  if (write) {
    *reg = data;
    plic_update();
  }
  return *reg;
}

static uint64_t clock_sample(unsigned action, bool executing)
{
  expect(JOURNAL_CLOCK, 24);
  if (!nemu_md_clint || payload[0] < last_clock || payload[1] != action || payload[2] != executing)
    reject("invalid clock order, action or instruction context");
  last_clock = payload[0];
  clocks++;
  return last_clock;
}

static void timer_sample(bool executing)
{
  uint64_t ticks = clock_sample(NEMU_JOURNAL_CLOCK_UPDATE, executing);
  for (unsigned hart = 0; hart < machine.harts; hart++) {
    if (machine.threaded && hart != current->hart) continue;
    CPU_state *state = harts[hart].live;
    state->sr[CSR_MIP] = (state->sr[CSR_MIP] & ~(word_t)0x88) |
        (msip[hart] ? 8 : 0) | (ticks >= state->mtimecmp ? 0x80 : 0);
#ifdef CONFIG_RV64
    uint64_t compare = state->sr[0x14d];
#else
    uint64_t compare = ((uint64_t)state->sr[0x15d] << 32) | state->sr[0x14d];
    state->sr[CSR_TIMEH] = ticks >> 32;
#endif
    state->stip = ticks >= compare;
    state->sr[CSR_TIME] = ticks;
    state->sr[CSR_SIP] = riscv_hart_mip_value(state) & state->sr[CSR_MIDELEG] & (word_t)0x222;
  }
  if (machine.threaded) plic_update();
  advance();
  while (nemu_md_plic && event.kind == JOURNAL_PLIC_SOURCE && event.hart == current->hart) {
    expect(JOURNAL_PLIC_SOURCE, 16);
    if (!payload[0] || payload[0] > 32 || payload[1] != executing)
      reject("invalid PLIC source or instruction context");
    unsigned source = payload[0];
    plic_pending[source / 32] |= UINT32_C(1) << (source % 32);
    plic_update();
    plic_sources++;
    advance();
  }
  while (nemu_md_uart && event.kind == JOURNAL_UART_RX && event.hart == current->hart) {
    expect(JOURNAL_UART_RX, 16);
    if (payload[0] > 255 || payload[1] != executing) reject("invalid UART input byte/context");
    if (uart_count < sizeof(uart_fifo)) {
      uart_fifo[(uart_head + uart_count) % sizeof(uart_fifo)] = payload[0];
      uart_count++;
    }
    uart_rx++;
    advance();
    uart_signal();
  }
  while (nemu_md_net && event.kind == JOURNAL_NET_RX && event.hart == current->hart) net_receive();
}

void nemu_md_timer_update(void)
{
  if (!active || !nemu_md_clint) return;
  cpu_bus_lock();
  timer_sample(true);
  cpu_bus_unlock();
}

word_t nemu_replay_clint(paddr_t address, int size, bool write, word_t data)
{
  if (!active || !current->executing || !bus_depth || !nemu_md_clint_span(address, size, write))
    reject("invalid reference CLINT access");
  uint64_t offset = address - NEMU_JOURNAL_CLINT_BASE;
  uint64_t value;
  if (offset < 0x4000) {
    unsigned hart = offset / 4;
    if (write) msip[hart] = data & 1;
    value = msip[hart];
  } else if (offset < 0xbff8) {
    unsigned hart = (offset - 0x4000) / 8;
    unsigned shift = ((offset - 0x4000) % 8) * 8;
    uint64_t mask = UINT64_MAX >> ((8 - size) * 8);
    if (write) harts[hart].live->mtimecmp = (harts[hart].live->mtimecmp & ~(mask << shift)) |
        (((uint64_t)data & mask) << shift);
    value = harts[hart].live->mtimecmp >> shift;
  } else {
    value = 0;
  }
  if (write) {
    timer_sample(true);
  } else {
    uint64_t ticks = clock_sample(NEMU_JOURNAL_CLOCK_READ, true);
    if (offset >= 0xbff8) value = ticks >> ((offset - 0xbff8) * 8);
    advance();
  }
  return value & (UINT64_MAX >> ((8 - size) * 8));
}

static void invalidate(paddr_t address, int size)
{
  for (unsigned hart = 0; hart < machine.harts; hart++) {
    CPU_state *state = harts[hart].live;
    if (state->reservation_bytes &&
        (address >= state->reservation ? address - state->reservation < state->reservation_bytes
                                      : state->reservation - address < size)) {
      state->reservation = 0;
      state->reservation_bytes = 0;
    }
  }
}

static bool device_dma(uint64_t address, void *bytes, size_t size, bool write)
{
  if (!size) return true;
  if (size > (nemu_md_net ? NEMU_JOURNAL_NET_FRAME : NEMU_JOURNAL_DMA_LIMIT))
    reject("reference DMA size out of range");
  bool success = (address >= machine.ram_base && address - machine.ram_base < machine.ram_size &&
                 size <= machine.ram_size - (address - machine.ram_base)) ||
                (!write && in_rom(address) && size <= CONFIG_ROM_SIZE - (address - CONFIG_ROM_BASE));
  size_t data_size = write || success ? size : 0;
  expect(write ? JOURNAL_DMA_WRITE : JOURNAL_DMA_READ, 24 + data_size);
  if (payload[0] != address || payload[1] != size || payload[2] != success)
    reject("DMA address/size/success mismatch before reference access");
  const void *expected = write ? bytes : success ? guest_to_host(address) : NULL;
  if (data_size && memcmp(payload + 3, expected, data_size))
    reject("independent DMA data mismatch before reference access");
  if (success) {
    if (write) {
      invalidate(address, size);
      memcpy(guest_to_host(address), bytes, size);
    } else memcpy(bytes, expected, size);
    dma_bytes += size;
  }
  if (write) dma_writes++;
  else dma_reads++;
  advance();
  return success;
}

static bool rng_entropy(uint8_t *bytes, size_t size)
{
  if (!await_hart() || event.kind != JOURNAL_RNG_INPUT || event.length < 16 ||
      !size || size > NEMU_JOURNAL_ENTROPY_LIMIT || payload[0] != size || payload[1] > 1 ||
      event.length != 16 + (payload[1] ? size : 0)) reject("invalid raw RNG entropy event");
  bool success = payload[1];
  if (success) memcpy(bytes, payload + 2, size);
  rng_inputs++;
  advance();
  return success;
}

static uint64_t rng_address(unsigned offset)
{
  return (uint64_t)rng_registers[offset / 4] | ((uint64_t)rng_registers[offset / 4 + 1] << 32);
}

static uint32_t rng_fill(uint16_t head)
{
  uint32_t written = 0;
  for (unsigned visited = 0; visited < rng_registers[0x38 / 4]; visited++) {
    if (head >= rng_registers[0x38 / 4]) break;
    uint8_t descriptor[16];
    if (!device_dma(rng_address(0x80) + 16ull * head, descriptor, sizeof(descriptor), false)) break;
    uint64_t address;
    uint32_t remaining;
    uint16_t flags, next;
    memcpy(&address, descriptor, 8);
    memcpy(&remaining, descriptor + 8, 4);
    memcpy(&flags, descriptor + 12, 2);
    memcpy(&next, descriptor + 14, 2);
    if (!(flags & 2)) break;
    while (remaining) {
      uint8_t entropy[NEMU_JOURNAL_ENTROPY_LIMIT];
      size_t chunk = remaining < sizeof(entropy) ? remaining : sizeof(entropy);
      if (!rng_entropy(entropy, chunk) || !device_dma(address, entropy, chunk, true)) return written;
      address += chunk;
      remaining -= chunk;
      written += chunk;
    }
    if (!(flags & 1)) break;
    head = next;
  }
  return written;
}

static void rng_notify(void)
{
  unsigned count = rng_registers[0x38 / 4];
  uint64_t available = rng_address(0x90), used = rng_address(0xa0);
  if (rng_registers[0x30 / 4] || !count || !rng_registers[0x44 / 4] ||
      !(rng_registers[0x70 / 4] & 4) || !rng_address(0x80) || !available || !used) return;
  for (;;) {
    uint16_t available_index, head, used_index;
    if (!device_dma(available + 2, &available_index, 2, false) || available_index == rng_available_index) return;
    if (!device_dma(available + 4 + 2ull * (rng_available_index % count), &head, 2, false)) return;
    rng_available_index++;
    if (head >= count) return;
    uint32_t length = rng_fill(head), identifier = head;
    if (!device_dma(used + 2, &used_index, 2, false)) return;
    uint64_t element = used + 4 + 8ull * (used_index % count);
    if (!device_dma(element, &identifier, 4, true) || !device_dma(element + 4, &length, 4, true)) return;
    used_index++;
    if (!device_dma(used + 2, &used_index, 2, true)) return;
    rng_registers[0x60 / 4] |= 1;
    expect(JOURNAL_RNG_IRQ, 16);
    if (payload[0] != NEMU_JOURNAL_RNG_IRQ || payload[1] != 1) reject("derived RNG IRQ mismatch");
    plic_pending[0] |= UINT32_C(1) << NEMU_JOURNAL_RNG_IRQ;
    plic_update();
    rng_irqs++;
    advance();
  }
}

word_t nemu_replay_rng(paddr_t address, int size, bool write, word_t data)
{
  if (!active || !current->executing || !bus_depth || !nemu_md_rng_span(address, size))
    reject("invalid reference RNG access");
  unsigned offset = address - NEMU_JOURNAL_RNG_BASE;
  uint32_t value = data;
  if (write) {
    switch (offset) {
      case 0x20: rng_driver_features[rng_registers[0x24 / 4] & 1] = value; break;
      case 0x14: case 0x24: case 0x30:
      case 0x80: case 0x84: case 0x90: case 0x94: case 0xa0: case 0xa4:
        rng_registers[offset / 4] = value; break;
      case 0x38: rng_registers[offset / 4] = value < 8 ? value : 8; break;
      case 0x44: rng_registers[offset / 4] = value & 1; break;
      case 0x50: if (!value) rng_notify(); break;
      case 0x64: rng_registers[0x60 / 4] &= ~value; break;
      case 0x70:
        rng_registers[offset / 4] = value;
        if (!value) {
          memset(rng_registers, 0, sizeof(rng_registers));
          memset(rng_driver_features, 0, sizeof(rng_driver_features));
          rng_available_index = 0;
        }
        break;
    }
    return 0;
  }
  switch (offset) {
    case 0x00: return 0x74726976;
    case 0x04: return 2;
    case 0x08: return 4;
    case 0x0c: return 0x554d4551;
    case 0x10: return rng_registers[0x14 / 4] == 1;
    case 0x34: return rng_registers[0x30 / 4] ? 0 : 8;
    case 0x44: case 0x60: case 0x70: return rng_registers[offset / 4];
    default: return 0;
  }
}

typedef struct {
  uint64_t address;
  uint32_t length;
  uint16_t flags, next;
} ReplayNetDescriptor;

static bool net_descriptor(ReplayNetQueue *queue, uint16_t index, ReplayNetDescriptor *descriptor)
{
  _Static_assert(sizeof(ReplayNetDescriptor) == 16, "net descriptor layout");
  return index < queue->size && device_dma(queue->descriptors + 16ull * index, descriptor, 16, false);
}

static bool net_pop(ReplayNetQueue *queue, uint16_t *head)
{
  if (!queue->size || !queue->ready || !queue->descriptors || !queue->available || !queue->used || !(net_status & 4))
    return false;
  uint16_t available;
  if (!device_dma(queue->available + 2, &available, 2, false) || available == queue->consumed) return false;
  if (!device_dma(queue->available + 4 + 2ull * (queue->consumed % queue->size), head, 2, false)) return false;
  queue->consumed++;
  return *head < queue->size;
}

static bool net_push(ReplayNetQueue *queue, uint16_t head, uint32_t length)
{
  uint16_t used;
  if (!device_dma(queue->used + 2, &used, 2, false)) return false;
  uint64_t element = queue->used + 4 + 8ull * (used % queue->size);
  uint32_t identifier = head;
  if (!device_dma(element, &identifier, 4, true) || !device_dma(element + 4, &length, 4, true)) return false;
  used++;
  if (!device_dma(queue->used + 2, &used, 2, true)) return false;
  net_interrupt_status |= 1;
  expect(JOURNAL_NET_IRQ, 16);
  if (payload[0] != NEMU_JOURNAL_NET_IRQ || payload[1] != current->executing) reject("derived NET IRQ mismatch");
  plic_pending[0] |= UINT32_C(1) << NEMU_JOURNAL_NET_IRQ;
  plic_update();
  net_irqs++;
  advance();
  return true;
}

static size_t net_copy(ReplayNetQueue *queue, uint16_t head, uint8_t *frame, size_t length, bool write)
{
  size_t copied = 0;
  for (unsigned count = 0; count < queue->size && (!write || copied < length); count++) {
    ReplayNetDescriptor descriptor;
    if (!net_descriptor(queue, head, &descriptor) || !!(descriptor.flags & 2) != write) return 0;
    if (!write && descriptor.length > length - copied) return 0;
    size_t chunk = descriptor.length < length - copied ? descriptor.length : length - copied;
    if (!device_dma(descriptor.address, frame + copied, chunk, write)) return 0;
    copied += chunk;
    if (!(descriptor.flags & 1)) return !write || copied == length ? copied : 0;
    head = descriptor.next;
  }
  return write && copied == length ? copied : 0;
}

static void net_receive(void)
{
  if (!await_hart() || !bus_depth || event.kind != JOURNAL_NET_RX || event.length < 16 ||
      payload[0] > NEMU_JOURNAL_NET_FRAME - NEMU_JOURNAL_NET_HEADER ||
      event.length != 16 + payload[0] || payload[1] != current->executing) reject("invalid raw NET input");
  uint8_t frame[NEMU_JOURNAL_NET_FRAME];
  size_t size = payload[0];
  memset(frame, 0, NEMU_JOURNAL_NET_HEADER);
  memcpy(frame + NEMU_JOURNAL_NET_HEADER, payload + 2, size);
  net_rx++;
  net_rx_bytes += size;
  advance();
  uint64_t result = size;
  unsigned disposition = 0;
  uint16_t head;
  if (net_pop(&net_queues[0], &head)) {
    size_t written = net_copy(&net_queues[0], head, frame, size + NEMU_JOURNAL_NET_HEADER, true);
    bool committed = net_push(&net_queues[0], head, written);
    result = written && committed ? size : UINT64_MAX;
    disposition = written && committed ? 1 : 2;
  }
  expect(JOURNAL_NET_RX_RESULT, 24);
  if (payload[0] != result || payload[1] != disposition || payload[2] != current->executing)
    reject("derived NET receive result mismatch");
  net_rx_drops += disposition != 1;
  advance();
}

static void net_transmit(void)
{
  uint16_t head;
  uint8_t frame[NEMU_JOURNAL_NET_FRAME];
  while (net_pop(&net_queues[1], &head)) {
    size_t length = net_copy(&net_queues[1], head, frame, sizeof(frame), false);
    if (length >= NEMU_JOURNAL_NET_HEADER) {
      size_t bytes = length - NEMU_JOURNAL_NET_HEADER;
      expect(JOURNAL_NET_TX, 16 + bytes);
      if (payload[0] != bytes || payload[1] != 1 || memcmp(payload + 2, frame + NEMU_JOURNAL_NET_HEADER, bytes))
        reject("derived NET transmit data mismatch before external effect");
      net_tx++;
      net_tx_bytes += bytes;
      advance();
      while (event.kind == JOURNAL_NET_RX && event.hart == current->hart) net_receive();
    }
    if (!net_push(&net_queues[1], head, length)) return;
  }
}

word_t nemu_replay_net(paddr_t address, int size, bool write, word_t data)
{
  if (!active || !current->executing || !bus_depth || !nemu_md_net_span(address, size, write))
    reject("invalid reference NET access");
  unsigned offset = (address - NEMU_JOURNAL_NET_BASE) & ~3u;
  ReplayNetQueue *queue = net_queue_select < 2 ? &net_queues[net_queue_select] : NULL;
  uint32_t value = data;
  if (write) {
    switch (offset) {
      case 0x14: net_features_select = value; break;
      case 0x20: net_driver_features[net_driver_select & 1] = value; break;
      case 0x24: net_driver_select = value; break;
      case 0x30: net_queue_select = value; break;
      case 0x38: if (queue) queue->size = value < 256 ? value : 256; break;
      case 0x44: if (queue) queue->ready = value & 1; break;
      case 0x50: if (value == 1) net_transmit(); break;
      case 0x64: net_interrupt_status &= ~value; break;
      case 0x70:
        net_status = value;
        if (!value) {
          memset(net_queues, 0, sizeof(net_queues));
          memset(net_driver_features, 0, sizeof(net_driver_features));
          net_features_select = net_driver_select = net_queue_select = net_interrupt_status = 0;
        }
        break;
      case 0x80: case 0x84: case 0x90: case 0x94: case 0xa0: case 0xa4:
        if (queue) {
          uint64_t *target = offset < 0x90 ? &queue->descriptors : offset < 0xa0 ? &queue->available : &queue->used;
          if (offset & 4) *target = (*target & UINT32_MAX) | ((uint64_t)value << 32);
          else *target = (*target & ~UINT64_C(0xffffffff)) | value;
        }
        break;
    }
    return 0;
  }
  switch (offset) {
    case 0: value = 0x74726976; break;
    case 4: value = 2; break;
    case 8: value = 1; break;
    case 12: value = 0x554d4551; break;
    case 0x10: value = net_features_select == 0 ? 32 : net_features_select == 1 ? 1 : 0; break;
    case 0x34: value = queue ? 256 : 0; break;
    case 0x44: value = queue ? queue->ready : 0; break;
    case 0x60: value = net_interrupt_status; break;
    case 0x70: value = net_status; break;
    case 0x100: value = 0x12005452; break;
    case 0x104: value = 0x5634; break;
    default: value = 0;
  }
  return (value >> ((address & 3) * 8)) & (UINT64_MAX >> ((8 - size) * 8));
}

typedef struct {
  uint64_t address;
  uint32_t length;
  uint16_t flags, next;
} ReplayBlockDescriptor;

static unsigned block_queue_size(void)
{
  return block.size ? block.size : 256;
}

static bool block_descriptor(unsigned index, ReplayBlockDescriptor *descriptor)
{
  return index < block_queue_size() && device_dma(block.descriptors + 16ull * index, descriptor, 16, false);
}

static void block_effect(uint64_t offset, uint8_t *bytes, size_t size, bool write)
{
  expect(write ? JOURNAL_BLOCK_WRITE : JOURNAL_BLOCK_READ, 16 + size);
  if (offset > block_image_size || size > block_image_size - offset || payload[0] != offset || payload[1] != size ||
      memcmp(payload + 2, write ? bytes : block_disk + offset, size))
    reject("independent BLOCK data/offset/size mismatch");
  if (write) {
    memcpy(block_disk + offset, bytes, size);
    block_writes++;
  } else {
    memcpy(bytes, block_disk + offset, size);
    block_reads++;
  }
  block_bytes += size;
  advance();
}

static bool block_transfer(unsigned type, ReplayBlockDescriptor descriptor, uint64_t *offset, uint32_t *written)
{
  if (descriptor.length > 0x100000 || (type != 8 &&
      (*offset > block_image_size || descriptor.length > block_image_size - *offset))) return false;
  static const uint8_t identity[20] = "NEMU-VIRTIO-BLK";
  uint8_t bytes[65536];
  for (uint32_t done = 0; done < descriptor.length;) {
    size_t size = descriptor.length - done < sizeof(bytes) ? descriptor.length - done : sizeof(bytes);
    if (type == 1) {
      if (!device_dma(descriptor.address + done, bytes, size, false)) return false;
      block_effect(*offset, bytes, size, true);
    } else {
      if (type == 0) block_effect(*offset, bytes, size, false);
      else {
        memset(bytes, 0, size);
        for (size_t index = 0; index < size && done + index < sizeof(identity); index++)
          bytes[index] = identity[done + index];
      }
      if (!device_dma(descriptor.address + done, bytes, size, true)) return false;
      *written += size;
    }
    if (type != 8) *offset += size;
    done += size;
  }
  return true;
}

static void block_finish(uint16_t head, uint32_t length)
{
  uint16_t used;
  if (!device_dma(block.used + 2, &used, 2, false)) return;
  uint64_t address = block.used + 4 + 8ull * (used % block_queue_size());
  uint32_t id = head;
  uint16_t next = used + 1;
  if (!device_dma(address, &id, 4, true) || !device_dma(address + 4, &length, 4, true) ||
      !device_dma(block.used + 2, &next, 2, true)) return;
  block.irq |= 1;
  expect(JOURNAL_BLOCK_IRQ, 16);
  if (payload[0] != 1 || payload[1] != 1) reject("derived BLOCK IRQ mismatch");
  plic_pending[0] |= 2;
  plic_update();
  block_irqs++;
  advance();
}

static void block_request(uint16_t head)
{
  ReplayBlockDescriptor descriptor;
  struct { uint32_t type, reserved; uint64_t sector; } request;
  if (!block_descriptor(head, &descriptor) || descriptor.length < 16 ||
      !(descriptor.flags & 1) || (descriptor.flags & 2) || !device_dma(descriptor.address, &request, 16, false)) {
    block_finish(head, 0);
    return;
  }
  uint64_t offset = 0;
  bool success = request.type == 8;
  if (request.sector <= UINT64_MAX / 512 && request.sector * 512 < block_image_size) {
    offset = request.sector * 512;
    success = true;
  }
  bool supported = request.type == 0 || request.type == 1 || request.type == 8;
  uint32_t written = 0;
  unsigned index = descriptor.next;
  for (unsigned count = 1; count < block_queue_size(); count++) {
    if (!block_descriptor(index, &descriptor)) break;
    if (!(descriptor.flags & 1)) {
      uint8_t status = success && supported ? 0 : 1;
      if (descriptor.length && (descriptor.flags & 2) && device_dma(descriptor.address, &status, 1, true)) written++;
      break;
    }
    if (!supported || !!(descriptor.flags & 2) != (request.type != 1)) success = false;
    if (success && !block_transfer(request.type, descriptor, &offset, &written)) success = false;
    index = descriptor.next;
  }
  block_finish(head, written);
}

static void block_notify(void)
{
  if (!block_image_size || block.queue_select || !block.ready || !(block.status & 4) ||
      !block.descriptors || !block.available || !block.used) return;
  uint16_t available;
  if (!device_dma(block.available + 2, &available, 2, false)) return;
  while (block.consumed != available) {
    uint16_t head;
    if (!device_dma(block.available + 4 + 2ull * (block.consumed % block_queue_size()), &head, 2, false)) return;
    if (head < block_queue_size()) block_request(head);
    block.consumed++;
  }
}

word_t nemu_replay_block(paddr_t address, int size, bool write, word_t data)
{
  if (!active || !current->executing || !bus_depth || !nemu_md_block_span(address, size))
    reject("invalid reference BLOCK access");
  unsigned offset = address - NEMU_JOURNAL_BLOCK_BASE;
  uint32_t value = data;
  if (write) {
    switch (offset) {
      case 0x14: block.feature_select = value; break;
      case 0x20: block.driver_features[block.driver_select & 1] = value; break;
      case 0x24: block.driver_select = value; break;
      case 0x30: block.queue_select = value; break;
      case 0x38: block.size = value > 256 ? 256 : value; break;
      case 0x44: block.ready = value & 1; break;
      case 0x50: block_notify(); break;
      case 0x64: block.irq &= ~value; break;
      case 0x70:
        block.status = value;
        if (!value) memset(&block, 0, sizeof(block));
        break;
      case 0x80: block.descriptors = (block.descriptors & ~UINT64_C(0xffffffff)) | value; break;
      case 0x84: block.descriptors = (block.descriptors & UINT32_MAX) | (uint64_t)value << 32; break;
      case 0x90: block.available = (block.available & ~UINT64_C(0xffffffff)) | value; break;
      case 0x94: block.available = (block.available & UINT32_MAX) | (uint64_t)value << 32; break;
      case 0xa0: block.used = (block.used & ~UINT64_C(0xffffffff)) | value; break;
      case 0xa4: block.used = (block.used & UINT32_MAX) | (uint64_t)value << 32; break;
      default: break;
    }
    return 0;
  }
  switch (offset) {
    case 0: return 0x74726976;
    case 4: return 2;
    case 8: return block_image_size ? 2 : 0;
    case 12: return 0x554d4551;
    case 0x10: return block.feature_select == 1 ? 1 : 6;
    case 0x34: return block_image_size && !block.queue_select ? 256 : 0;
    case 0x44: return block.ready;
    case 0x60: return block.irq;
    case 0x70: return block.status;
    case 0x100: return (uint32_t)(block_image_size / 512);
    case 0x104: return block_image_size / 512 >> 32;
    case 0x108: return 0x100000;
    case 0x10c: return 128;
    default: return 0;
  }
}

static bool initial_block(void)
{
  if (!nemu_md_block) return true;
  if (!next_event() || event.kind != JOURNAL_BLOCK_IMAGE || event.hart || event.length != 16 ||
      payload[0] > NEMU_JOURNAL_BLOCK_MAX_IMAGE || payload[1] > (payload[0] + 4095) / 4096) {
    fail("invalid BLOCK image geometry");
    return false;
  }
  block_image_size = payload[0];
  block_pages = payload[1];
  block_disk = calloc(block_image_size ? block_image_size : 1, 1);
  if (!block_disk) {
    fail("BLOCK image allocation failed");
    return false;
  }
  uint64_t previous = UINT64_MAX;
  for (uint64_t index = 0; index < block_pages; index++) {
    if (!next_event() || event.kind != JOURNAL_BLOCK_PAGE || event.hart || event.length <= 8 ||
        payload[0] % 4096 || payload[0] >= block_image_size || (index && payload[0] <= previous) ||
        event.length - 8 != (block_image_size - payload[0] < 4096 ? block_image_size - payload[0] : 4096)) {
      fail("invalid BLOCK initial page");
      return false;
    }
    previous = payload[0];
    memcpy(block_disk + previous, payload + 1, event.length - 8);
  }
  return true;
}

static void retire(void)
{
  if (!await_hart() || event.kind != JOURNAL_END || event.length < 32 || (event.length - 32) % 16)
    reject("invalid retirement record");
  if (payload[0] != cpu.inst || payload[1] != cpu.instruction_trapped || payload[2] ||
      payload[3] != (nemu_state.state == NEMU_END) || nemu_md_frame.error || nemu_state.state == NEMU_ABORT)
    reject("instruction/trap/termination mismatch");
  uint64_t previous_index = 0;
  for (size_t index = 4; index < event.length / 8; index += 2) {
    uint64_t slot = payload[index];
    if (slot >= NEMU_JOURNAL_STATE_WORDS || (index > 4 && slot <= previous_index))
      reject("invalid retirement state delta");
    memcpy((uint8_t *)&current->expected + slot * 8, &payload[index + 1], 8);
    previous_index = slot;
  }
  NemuDiffState actual;
  nemu_md_capture(&actual);
  if (memcmp(&actual, &current->expected, sizeof(actual))) {
    for (unsigned slot = 0; slot < NEMU_JOURNAL_STATE_WORDS; slot++) {
      uint64_t actual_value, wanted_value;
      memcpy(&actual_value, (uint8_t *)&actual + slot * 8, 8);
      memcpy(&wanted_value, (uint8_t *)&current->expected + slot * 8, 8);
      if (actual_value != wanted_value) {
        fprintf(stderr, "  state word=%u ref=0x%" PRIx64 " dut=0x%" PRIx64 " pc=" FMT_WORD "\n",
                slot, actual_value, wanted_value, cpu.pc);
        reject("architectural or reservation state mismatch");
      }
    }
  }
  endings += payload[3];
  current->executing = false;
  current->retired++;
  advance();
}

static void *worker(void *argument)
{
  current = argument;
  check_thread(pthread_mutex_lock(&mutex));
  if (nemu_setjmp(escape) == 0) {
    nemu_md_restore(&current->expected);
    current->live = &cpu;
    nemu_state.state = NEMU_RUNNING;
    ready++;
    check_thread(pthread_cond_broadcast(&changed));
    while (!started && !failed) check_thread(pthread_cond_wait(&changed, &mutex));
    while (await_hart()) {
      if (machine.threaded) {
        cpu_bus_lock();
      }
      if (nemu_md_clint && event.kind == JOURNAL_CLOCK) {
        timer_sample(false);
        if (!machine.threaded) continue;
      }
      if (machine.threaded) {
        if (event.kind == JOURNAL_UNLOCK) {
          cpu_bus_unlock();
          continue;
        }
      }
      expect(JOURNAL_BEGIN, 8);
      if (current->executing || payload[0] != cpu.pc || nemu_state.state != NEMU_RUNNING ||
          (!nemu_md_interrupts && riscv_intr_may_pending()))
        reject("instruction start PC/state mismatch");
      if (!machine.threaded)
        for (unsigned hart = 0; hart < machine.harts; hart++)
          if (harts[hart].executing) reject("overlapping cooperative instructions");
      current->executing = true;
      unsigned executing = 0;
      for (unsigned hart = 0; hart < machine.harts; hart++) executing += harts[hart].executing;
      if (executing > maximum_active) maximum_active = executing;
      nemu_md_reset_frame();
      advance();
      if (machine.threaded) cpu_bus_unlock();
      if (nemu_md_interrupts) {
        word_t cause = riscv_intr_may_pending() ? isa_query_intr() : INTR_EMPTY;
        if (cause != INTR_EMPTY) {
          if (machine.threaded) cpu_bus_lock();
          expect(JOURNAL_INTERRUPT, 16);
          if (payload[0] != cause || payload[1] != cpu.pc)
            reject("interrupt cause or entry PC mismatch");
          interrupts++;
          advance();
          if (machine.threaded) cpu_bus_unlock();
          cpu.pc = isa_raise_intr(cause, cpu.pc);
        }
      }
      nemu_md_exec_one();
      if (machine.threaded) cpu_bus_lock();
      retire();
      if (machine.threaded) cpu_bus_unlock();
    }
  }
  check_thread(pthread_mutex_unlock(&mutex));
  return NULL;
}

static bool initial_state(unsigned hart)
{
  NemuDiffState *state = &harts[hart].expected;
  memcpy(state, payload, sizeof(*state));
  if (state->gpr[0] || state->csr[CSR_MHARTID] != hart || state->privilege > 3 ||
      state->privilege == 2 || state->reservation_bytes || state->stip > 1 || state->seip > 1) return false;
#ifndef CONFIG_RV64
  if (state->pc > UINT32_MAX) return false;
  for (unsigned index = 0; index < 32; index++)
    if (state->gpr[index] > UINT32_MAX) return false;
  for (unsigned index = 0; index < 4096; index++)
    if (state->csr[index] > UINT32_MAX) return false;
#endif
  return true;
}

static bool initialize(void)
{
  uint16_t endian = 1;
  if (*(uint8_t *)&endian != 1 || fread(&machine, sizeof(machine), 1, input) != 1 ||
      memcmp(machine.magic, NEMU_JOURNAL_MAGIC, 8) ||
      (machine.version != NEMU_JOURNAL_VERSION && machine.version != NEMU_JOURNAL_IRQ_VERSION &&
       machine.version != NEMU_JOURNAL_CLINT_VERSION && machine.version != NEMU_JOURNAL_PLIC_VERSION &&
       machine.version != NEMU_JOURNAL_UART_VERSION && machine.version != NEMU_JOURNAL_TLB_VERSION &&
       machine.version != NEMU_JOURNAL_RNG_VERSION && machine.version != NEMU_JOURNAL_NET_VERSION &&
       machine.version != NEMU_JOURNAL_BLOCK_VERSION) ||
      machine.xlen != XLEN || !machine.harts || machine.harts > NEMU_DIFF_MULTI_HARTS ||
      machine.ram_base != PMEM_LEFT || machine.ram_size != CONFIG_MSIZE ||
      machine.isa_features != nemu_md_features() || machine.threaded > 1 ||
      (machine.version >= NEMU_JOURNAL_TLB_VERSION && machine.threaded != 1)) {
    fail("journal version or machine configuration mismatch");
    return false;
  }
  nemu_md_interrupts = machine.version >= NEMU_JOURNAL_IRQ_VERSION;
  nemu_md_clint = machine.version >= NEMU_JOURNAL_CLINT_VERSION;
  nemu_md_plic = machine.version >= NEMU_JOURNAL_PLIC_VERSION;
  nemu_md_uart = machine.version >= NEMU_JOURNAL_UART_VERSION;
  nemu_md_tlb_retain = machine.version >= NEMU_JOURNAL_TLB_VERSION;
  nemu_md_rng = machine.version >= NEMU_JOURNAL_RNG_VERSION;
  nemu_md_net = machine.version >= NEMU_JOURNAL_NET_VERSION;
  nemu_md_block = machine.version >= NEMU_JOURNAL_BLOCK_VERSION;
  if (!initial_block()) return false;
  nemu_md_harts = machine.harts;
  void init_mem(void);
  init_mem();
  memset(guest_to_host(PMEM_LEFT), 0, CONFIG_MSIZE);
  if (in_rom(CONFIG_ROM_BASE)) memset(guest_to_host(CONFIG_ROM_BASE), 0, CONFIG_ROM_SIZE);
  size_t ram_pages = (CONFIG_MSIZE + 4095ull) / 4096;
  bool *pages = calloc(ram_pages + 16, sizeof(*pages));
  if (!pages) {
    fail("initial page bookkeeping allocation failed");
    return false;
  }
  unsigned states = 0;
  while (next_event()) {
    if (event.kind == JOURNAL_MEMORY) {
      uint64_t address = payload[0];
      bool ram = address >= PMEM_LEFT && address - PMEM_LEFT < CONFIG_MSIZE;
      bool rom = in_rom(address);
      if (event.length <= 8 || event.length > 4104 || address % 4096 ||
          (!ram && !rom) || (ram && event.length - 8 > CONFIG_MSIZE - (address - PMEM_LEFT)) ||
          (rom && event.length - 8 > CONFIG_ROM_SIZE - (address - CONFIG_ROM_BASE))) {
        fail("invalid initial memory page");
        break;
      }
      size_t page = ram ? (address - PMEM_LEFT) / 4096 : ram_pages + (address - CONFIG_ROM_BASE) / 4096;
      if (pages[page]) {
        fail("duplicate initial page");
        break;
      }
      pages[page] = true;
      memcpy(guest_to_host(address), &payload[1], event.length - 8);
    } else if (event.kind == JOURNAL_STATE) {
      if ((states & (1u << event.hart)) || event.length != sizeof(NemuDiffState) || !initial_state(event.hart)) {
        fail("invalid initial hart state");
        break;
      }
      NemuDiffState *state = &harts[event.hart].expected;
      if (nemu_md_clint && (state->mtimecmp != UINT64_MAX || state->stip || state->seip || (state->csr[CSR_MIP] & 0x88))) {
        fail("CLINT replay requires reset peripheral state");
        break;
      }
      if (nemu_md_plic && (state->csr[CSR_MIP] & 0x800)) {
        fail("PLIC replay requires clear MEIP");
        break;
      }
      states |= 1u << event.hart;
    } else {
      break;
    }
  }
  free(pages);
  if (states != (1u << machine.harts) - 1 || complete) fail("missing initial states or execution");
  return !failed;
}

static int consume_input(void)
{
  if (setvbuf(input, input_buffer, _IOFBF, sizeof(input_buffer))) {
    fail("input buffer setup failed");
    fclose(input);
    return -1;
  }
  if (!initialize()) {
    free(block_disk);
    fclose(input);
    return -1;
  }
  nemu_md_enabled = true;
  nemu_md_invalidate = invalidate;
  active = true;
  unsigned created = 0;
  for (unsigned hart = 0; hart < machine.harts; hart++) {
    harts[hart].hart = hart;
    int result = pthread_create(&harts[hart].thread, NULL, worker, &harts[hart]);
    if (result) {
      check_thread(pthread_mutex_lock(&mutex));
      fail("pthread_create failed");
      check_thread(pthread_mutex_unlock(&mutex));
      break;
    }
    created++;
  }
  check_thread(pthread_mutex_lock(&mutex));
  while (ready != created && !failed) check_thread(pthread_cond_wait(&changed, &mutex));
  started = true;
  check_thread(pthread_cond_broadcast(&changed));
  check_thread(pthread_mutex_unlock(&mutex));
  for (unsigned hart = 0; hart < created; hart++) check_thread(pthread_join(harts[hart].thread, NULL));
  active = false;
  nemu_md_invalidate = NULL;
  if (fclose(input)) fail("input close failed");
  free(block_disk);
  uint64_t checked = 0;
  for (unsigned hart = 0; hart < machine.harts; hart++) checked += harts[hart].retired;
  printf("NEMU_REPLAY checked=%" PRIu64 " events=%" PRIu64 " bytes=%" PRIu64
         " harts=%" PRIu64 " buffer_bytes=%zu maximum_active=%u interleaved=%" PRIu64
         " interrupts=%" PRIu64 " clocks=%" PRIu64 " io_requests=%" PRIu64 " plic_sources=%" PRIu64
         " uart_rx=%" PRIu64 " uart_irqs=%" PRIu64 " uart_tx=%" PRIu64
         " dma_reads=%" PRIu64 " dma_writes=%" PRIu64 " dma_bytes=%" PRIu64
         " rng_inputs=%" PRIu64 " rng_irqs=%" PRIu64
         " net_rx=%" PRIu64 " net_tx=%" PRIu64 " net_irqs=%" PRIu64
         " net_rx_bytes=%" PRIu64 " net_tx_bytes=%" PRIu64 " net_rx_drops=%" PRIu64
         " block_reads=%" PRIu64 " block_writes=%" PRIu64 " block_bytes=%" PRIu64 " block_irqs=%" PRIu64
         " block_image_size=%" PRIu64 " block_pages=%" PRIu64 " status=%s\n",
         checked, sequence, consumed, machine.harts, sizeof(input_buffer), maximum_active, interleaved, interrupts, clocks, io_requests, plic_sources,
         uart_rx, uart_irqs, uart_tx,
         dma_reads, dma_writes, dma_bytes, rng_inputs, rng_irqs,
         net_rx, net_tx, net_irqs, net_rx_bytes, net_tx_bytes, net_rx_drops,
         block_reads, block_writes, block_bytes, block_irqs, block_image_size, block_pages,
         !failed && complete ? "OK" : "FAIL");
  return !failed && complete ? 0 : -1;
}

static int run(const char *path)
{
  if (claimed || nemu_md_enabled || !path) return -1;
  claimed = true;
  input = fopen(path, "rb");
  if (!input) {
    fail("cannot open journal");
    return -1;
  }
  return consume_input();
}

static int run_fd(int descriptor)
{
  if (claimed || nemu_md_enabled || descriptor < 0) return -1;
  claimed = true;
  struct stat info;
  int flags = fcntl(descriptor, F_GETFL);
  if (flags < 0 || (flags & O_ACCMODE) != O_RDONLY || (flags & O_NONBLOCK) ||
      fstat(descriptor, &info) || !S_ISFIFO(info.st_mode)) {
    fail("stream requires a blocking read-only pipe descriptor");
    return -1;
  }
  int duplicate = fcntl(descriptor, F_DUPFD_CLOEXEC, 3);
  if (duplicate < 0 || !(input = fdopen(duplicate, "rb"))) {
    if (duplicate >= 0) close(duplicate);
    fail("cannot duplicate input pipe");
    return -1;
  }
  return consume_input();
}

__EXPORT const NemuReplayAPI *nemu_difftest_replay_query(uint32_t version, uint32_t size)
{
  static const NemuReplayAPI api = {
    .version = NEMU_DIFF_REPLAY_VERSION, .size = sizeof(NemuReplayAPI),
    .journal_version = NEMU_JOURNAL_VERSION, .xlen = XLEN, .run = run,
  };
  return version == api.version && size == api.size ? &api : NULL;
}

__EXPORT const NemuStreamAPI *nemu_difftest_stream_query(uint32_t version, uint32_t size)
{
  static const NemuStreamAPI api = {
    .version = NEMU_DIFF_STREAM_VERSION, .size = sizeof(NemuStreamAPI),
    .journal_version = NEMU_JOURNAL_VERSION, .xlen = XLEN, .run_fd = run_fd,
  };
  return version == api.version && size == api.size ? &api : NULL;
}
#endif

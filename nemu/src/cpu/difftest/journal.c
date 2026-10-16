#include <cpu/diffjournal.h>
#include <cpu/diffstate.h>

#ifdef NEMU_HAS_SMP
#include <cpu/cpu.h>
#include <cpu/multidiff.h>
#include <cpu/thread.h>
#include <difftest-journal.h>
#include <difftest-vector.h>
#include <isa.h>
#include <isa-extensions.h>
#include <memory/paddr.h>
#include <utils.h>
#include <fcntl.h>
#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <sys/stat.h>
#include <unistd.h>

_Static_assert(sizeof(NemuDiffState) == NEMU_JOURNAL_STATE_WORDS * 8, "journal state layout changed");
_Static_assert(sizeof(cpu.vreg) == sizeof(NemuDiffVectorState), "journal vector layout changed");
_Static_assert(sizeof(NemuJournalHeader) == 64, "journal header layout changed");
_Static_assert(sizeof(NemuJournalRecord) == 40, "journal event layout changed");

const char *nemu_journal_path;
const char *nemu_plic_input_path;
const char *nemu_uart_input_path;
const char *nemu_rng_input_path;
const char *nemu_net_input_path;
bool nemu_net_script;
bool nemu_uart_stdin;
int nemu_journal_fd = -1;
uint64_t nemu_journal_max_bytes = 256ull << 20;
uint64_t nemu_journal_progress_interval;
bool nemu_journal_limit_explicit;
static FILE *journal;
static char journal_buffer[NEMU_JOURNAL_BUFFER_BYTES];
static struct sigaction previous_sigpipe;
static bool failed;
static uint64_t serial;
static uint64_t interrupts;
static uint64_t clocks;
static uint64_t io_requests;
static uint64_t last_clock;
static uint64_t plic_sources;
typedef struct { uint64_t ticks; unsigned value; } TimedInput;
static TimedInput inputs[4096], uart_inputs[4096];
static size_t input_count, input_next;
static size_t uart_input_count, uart_input_next;
static bool polling_inputs;
static bool polling_uart, uart_mmio;
static bool rng_mmio;
static bool net_mmio, polling_net, receiving_net;
static bool block_mmio;
static uint64_t block_reads, block_writes, block_bytes, block_irqs, block_image_size, block_pages;
static uint64_t net_rx, net_tx, net_irqs, net_rx_bytes, net_tx_bytes, net_rx_drops;
static uint64_t dma_reads, dma_writes, dma_bytes, rng_inputs, rng_irqs;
static bool uart_stdin_eof;
static uint64_t uart_rx, uart_irqs, uart_tx;
static uint64_t written = 64;
static uint64_t instructions[NEMU_MAX_HARTS];
static uint64_t retired;
static NemuDiffState previous[NEMU_MAX_HARTS];
static NemuDiffVectorState previous_vector[NEMU_MAX_HARTS];
static NEMU_TLS bool executing;
static NEMU_TLS bool participating;

static void fail(const char *reason)
{
  if (!failed) fprintf(stderr, "NEMU_JOURNAL_FAIL %s\n", reason);
  failed = true;
  nemu_stop_hart = nemu_hartid;
  nemu_state.halt_pc = cpu.pc;
  nemu_state.halt_ret = 1;
  nemu_state.state = NEMU_ABORT;
  cpu_thread_wake();
}

static void append_parts(unsigned kind, unsigned hart, const void *prefix, size_t prefix_size,
                         const void *data, size_t data_size)
{
  if (failed) return;
  size_t size = prefix_size + data_size;
  if (size + 40 > nemu_journal_max_bytes - written) {
    fail("journal byte limit reached");
    return;
  }
  written += size + 40;
  NemuJournalRecord header = {kind, serial++, hart, instructions[hart], size};
  if (fwrite(&header, sizeof(header), 1, journal) != 1 ||
      (prefix_size && fwrite(prefix, prefix_size, 1, journal) != 1) ||
      (data_size && fwrite(data, data_size, 1, journal) != 1)) fail("write error");
}

static void append(unsigned kind, unsigned hart, const void *payload, size_t size)
{
  append_parts(kind, hart, payload, size, NULL, 0);
}

static uint64_t input_number(const char *text, const char *name)
{
  char *end;
  errno = 0;
  uint64_t value = text ? strtoull(text, &end, 0) : 0;
  if (!text || text[0] < '0' || text[0] > '9' || errno || *end) {
    fprintf(stderr, "NEMU invalid %s input number\n", name);
    exit(EXIT_FAILURE);
  }
  return value;
}

static void load_inputs(const char *path, const char *name, TimedInput *entries,
                        size_t *count, unsigned minimum, unsigned maximum)
{
  if (!path) return;
  FILE *file = fopen(path, "r");
  if (!file) {
    fprintf(stderr, "NEMU %s input open: %s\n", name, strerror(errno));
    exit(EXIT_FAILURE);
  }
  char line[128];
  while (fgets(line, sizeof(line), file)) {
    bool oversized = strlen(line) == sizeof(line) - 1 && !strchr(line, '\n');
    char *time_text = strtok(line, " \t\r\n");
    if (!time_text) continue;
    uint64_t ticks = input_number(time_text, name);
    uint64_t value = input_number(strtok(NULL, " \t\r\n"), name);
    if (oversized || strtok(NULL, " \t\r\n") || *count == 4096 ||
        value < minimum || value > maximum || (*count && ticks < entries[*count - 1].ticks)) {
      fprintf(stderr, "NEMU invalid %s input schedule\n", name);
      exit(EXIT_FAILURE);
    }
    entries[*count].ticks = ticks;
    entries[(*count)++].value = value;
  }
  if (ferror(file) || !*count) {
    fprintf(stderr, "NEMU empty or unreadable %s input schedule\n", name);
    exit(EXIT_FAILURE);
  }
  fclose(file);
}

void nemu_journal_plic_source(unsigned source)
{
  if (!journal || !nemu_md_plic) return;
  if (!polling_inputs || source < 1 || source > 32) {
    fail("PLIC source outside serialized input poll");
    return;
  }
  uint64_t sample[] = {source, executing};
  append(JOURNAL_PLIC_SOURCE, nemu_hartid, sample, sizeof(sample));
  plic_sources++;
}

void nemu_journal_uart_irq(unsigned source)
{
  if (!journal || !nemu_md_uart) return;
  if ((!uart_mmio && !polling_uart) || source != NEMU_JOURNAL_UART_IRQ) {
    fail("UART IRQ outside modeled device operation");
    return;
  }
  uint64_t sample[] = {source, executing};
  append(JOURNAL_UART_IRQ, nemu_hartid, sample, sizeof(sample));
  uart_irqs++;
}

bool nemu_journal_dma_scope(void)
{
  return journal && !failed && nemu_worker && ((nemu_md_rng && rng_mmio && executing) ||
      (nemu_md_net && ((net_mmio && executing) || receiving_net)) ||
      (nemu_md_block && block_mmio && executing));
}

bool nemu_journal_dma(paddr_t address, const void *bytes, size_t size, bool write, bool success)
{
  if (!journal) return true;
  bool ram = address >= PMEM_LEFT && address - PMEM_LEFT < CONFIG_MSIZE &&
      size <= CONFIG_MSIZE - (address - PMEM_LEFT);
  bool rom = !write && in_rom(address) && size <= CONFIG_ROM_SIZE - (address - CONFIG_ROM_BASE);
  size_t limit = nemu_md_net ? NEMU_JOURNAL_NET_FRAME : NEMU_JOURNAL_DMA_LIMIT;
  if (!nemu_journal_dma_scope() || !size || size > limit || success != (ram || rom)) {
    fail("DMA outside modeled device scope, limit or physical map");
    return false;
  }
  uint64_t record[] = {address, size, success};
  size_t data_size = write || success ? size : 0;
  append_parts(write ? JOURNAL_DMA_WRITE : JOURNAL_DMA_READ, nemu_hartid, record, sizeof(record), bytes, data_size);
  if (write) dma_writes++;
  else dma_reads++;
  if (success) dma_bytes += size;
  return !failed;
}

bool nemu_journal_rng_input(const void *bytes, size_t size, bool success)
{
  if (!journal) return true;
  if (!nemu_journal_dma_scope() || !rng_mmio || !size || size > NEMU_JOURNAL_ENTROPY_LIMIT) {
    fail("RNG entropy outside modeled notification or size limit");
    return false;
  }
  uint64_t record[2 + NEMU_JOURNAL_ENTROPY_LIMIT / 8];
  record[0] = size;
  record[1] = success;
  if (success) memcpy(record + 2, bytes, size);
  append(JOURNAL_RNG_INPUT, nemu_hartid, record, 16 + (success ? size : 0));
  rng_inputs++;
  return !failed;
}

void nemu_journal_rng_irq(unsigned source)
{
  if (!journal || !nemu_md_rng) return;
  if (!nemu_journal_dma_scope() || !rng_mmio || source != NEMU_JOURNAL_RNG_IRQ) {
    fail("RNG IRQ outside modeled notification");
    return;
  }
  uint64_t record[] = {source, 1};
  append(JOURNAL_RNG_IRQ, nemu_hartid, record, sizeof(record));
  rng_irqs++;
}

bool nemu_journal_net_rx(const void *bytes, size_t size)
{
  if (!journal) return true;
  if (!nemu_md_net || receiving_net || (!net_mmio && !polling_net) || !nemu_worker ||
      size > NEMU_JOURNAL_NET_FRAME - NEMU_JOURNAL_NET_HEADER) {
    fail("NET RX outside modeled backend scope or size limit");
    return false;
  }
  uint64_t record[] = {size, executing};
  append_parts(JOURNAL_NET_RX, nemu_hartid, record, sizeof(record), bytes, size);
  receiving_net = true;
  net_rx++;
  net_rx_bytes += size;
  return !failed;
}

bool nemu_journal_block_data(uint64_t offset, const void *bytes, size_t size, bool write)
{
  if (!journal) return true;
  if (!nemu_md_block || !block_mmio || !executing || !nemu_worker ||
      !size || size > 65536 || offset >= block_image_size || size > block_image_size - offset) {
    fail("BLOCK transfer outside modeled notification or image");
    return false;
  }
  uint64_t record[] = {offset, size};
  append_parts(write ? JOURNAL_BLOCK_WRITE : JOURNAL_BLOCK_READ, nemu_hartid, record, sizeof(record), bytes, size);
  if (write) block_writes++;
  else block_reads++;
  block_bytes += size;
  return !failed;
}

void nemu_journal_block_irq(unsigned source)
{
  if (!journal || !nemu_md_block) return;
  if (!block_mmio || !executing || !nemu_worker || source != 1) {
    fail("BLOCK IRQ outside modeled notification");
    return;
  }
  uint64_t record[] = {source, 1};
  append(JOURNAL_BLOCK_IRQ, nemu_hartid, record, sizeof(record));
  block_irqs++;
}

bool nemu_journal_net_tx(const void *bytes, size_t size)
{
  if (!journal) return true;
  if (!nemu_md_net || !net_mmio || !executing || receiving_net || !nemu_worker ||
      size > NEMU_JOURNAL_NET_FRAME - NEMU_JOURNAL_NET_HEADER) {
    fail("NET TX outside modeled notification or size limit");
    return false;
  }
  uint64_t record[] = {size, 1};
  append_parts(JOURNAL_NET_TX, nemu_hartid, record, sizeof(record), bytes, size);
  net_tx++;
  net_tx_bytes += size;
  return !failed;
}

void nemu_journal_net_result(int64_t result, unsigned disposition)
{
  if (!journal) return;
  if (!nemu_md_net || !receiving_net || disposition > 2) {
    fail("NET RX result outside modeled receive");
    return;
  }
  uint64_t record[] = {(uint64_t)result, disposition, executing};
  append(JOURNAL_NET_RX_RESULT, nemu_hartid, record, sizeof(record));
  net_rx_drops += disposition != 1;
  receiving_net = false;
}

void nemu_journal_net_irq(unsigned source)
{
  if (!journal || !nemu_md_net) return;
  if ((!net_mmio && !receiving_net) || source != NEMU_JOURNAL_NET_IRQ) {
    fail("NET IRQ outside modeled queue operation");
    return;
  }
  uint64_t record[] = {source, executing};
  append(JOURNAL_NET_IRQ, nemu_hartid, record, sizeof(record));
  net_irqs++;
}

void nemu_journal_uart_tx(uint8_t byte, bool delivered)
{
  if (!journal || !nemu_md_uart) return;
  if (!uart_mmio || !executing || !delivered) {
    fail("UART output failed or outside modeled MMIO");
    return;
  }
  uint64_t sample[] = {byte, executing};
  append(JOURNAL_UART_TX, nemu_hartid, sample, sizeof(sample));
  uart_tx++;
}

#if defined(CONFIG_DEVICE) && defined(CONFIG_HAS_SERIAL)
static void receive_uart(uint8_t byte)
{
  void nemu_uart_receive(uint8_t byte);
  uint64_t sample[] = {byte, executing};
  append(JOURNAL_UART_RX, nemu_hartid, sample, sizeof(sample));
  uart_rx++;
  nemu_uart_receive(byte);
}
#endif

void nemu_journal_inputs(uint64_t ticks)
{
#ifdef CONFIG_DEVICE
  if (!journal || !nemu_md_plic) return;
  void plic_raise_irq(int source);
  polling_inputs = true;
  while (!failed && input_next < input_count && inputs[input_next].ticks <= ticks)
    plic_raise_irq(inputs[input_next++].value);
  polling_inputs = false;
#ifdef CONFIG_HAS_SERIAL
  polling_uart = true;
  while (!failed && uart_input_next < uart_input_count && uart_inputs[uart_input_next].ticks <= ticks)
    receive_uart(uart_inputs[uart_input_next++].value);
  if (!failed && nemu_uart_stdin && !uart_stdin_eof) {
    struct pollfd input = {.fd = STDIN_FILENO, .events = POLLIN};
    int ready = poll(&input, 1, 0);
    if ((ready < 0 && errno != EINTR) || (ready > 0 && (input.revents & (POLLERR | POLLNVAL))))
      fail("UART stdin poll failed");
    else if (ready > 0 && (input.revents & (POLLIN | POLLHUP))) {
      uint8_t bytes[64];
      ssize_t count = read(STDIN_FILENO, bytes, sizeof(bytes));
      if (count == 0) uart_stdin_eof = true;
      else if (count < 0 && errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK)
        fail("UART stdin read failed");
      else for (ssize_t index = 0; !failed && index < count; index++) receive_uart(bytes[index]);
    }
  }
  polling_uart = false;
#endif
#ifdef CONFIG_HAS_NET
  if (!failed && nemu_md_net) {
    void nemu_net_poll_inputs(uint64_t ticks);
    polling_net = true;
    nemu_net_poll_inputs(ticks);
    polling_net = false;
  }
#endif
#endif
}

void nemu_journal_bus(bool entering)
{
  if (journal && nemu_worker && participating)
    append(entering ? JOURNAL_LOCK : JOURNAL_UNLOCK, nemu_hartid, NULL, 0);
}

void nemu_journal_start_worker(void)
{
  if (journal && nemu_md_clint) participating = true;
}

void nemu_journal_clock(uint64_t ticks, unsigned action)
{
  if (!journal || !nemu_md_clint) return;
  if (ticks < last_clock) {
    fail("CLINT clock moved backwards");
    return;
  }
  last_clock = ticks;
  uint64_t sample[] = {ticks, action, executing};
  append(JOURNAL_CLOCK, nemu_hartid, sample, sizeof(sample));
  clocks++;
}

void nemu_md_timer_update(void)
{
#if defined(CONFIG_DEVICE) && defined(CONFIG_HAS_TIMER)
  if (multidiff_clint_active()) {
    void clint_update_mip(void);
    clint_update_mip();
  }
#endif
}

void nemu_journal_io(paddr_t address, int size, bool write, word_t data)
{
  if (!journal || !nemu_md_clint) return;
  if (!executing) {
    fail("MMIO request outside instruction");
    return;
  }
  NemuDiffMemory request = {.address = address, .data = write ? data : 0, .size = size, .write = write};
  request.data &= UINT64_MAX >> ((8 - size) * 8);
  append(JOURNAL_IO_REQUEST, nemu_hartid, &request, sizeof(request));
  uart_mmio = nemu_md_uart_span(address, size);
  rng_mmio = nemu_md_rng_span(address, size) && write && address == NEMU_JOURNAL_RNG_BASE + 0x50 && data == 0;
  net_mmio = nemu_md_net_span(address, size, write) && write && address == NEMU_JOURNAL_NET_BASE + 0x50 && data == 1;
  block_mmio = nemu_md_block_span(address, size) && write && address == NEMU_JOURNAL_BLOCK_BASE + 0x50;
  io_requests++;
}

void nemu_journal_memory(paddr_t address, int size, bool write, word_t data)
{
  if (!journal) return;
  uart_mmio = false;
  rng_mmio = false;
  net_mmio = false;
  block_mmio = false;
  if (!executing) {
    fail("memory operation outside an instruction");
    return;
  }
  NemuDiffMemory event = {.address = address, .data = data,
                          .size = size, .write = write};
  event.data &= UINT64_MAX >> ((8 - size) * 8);
  append(JOURNAL_ACCESS, nemu_hartid, &event, sizeof(event));
}

static void initial_memory(paddr_t base, size_t size)
{
  static const uint8_t zero[4096];
  struct { uint64_t address; uint8_t bytes[4096]; } page;
  for (size_t offset = 0; offset < size && !failed; offset += sizeof(page.bytes)) {
    size_t length = size - offset < sizeof(page.bytes) ? size - offset : sizeof(page.bytes);
    const uint8_t *source = guest_to_host(base + offset);
    if (!memcmp(source, zero, length)) continue;
    page.address = base + offset;
    memcpy(page.bytes, source, length);
    append(JOURNAL_MEMORY, 0, &page, sizeof(page.address) + length);
  }
}

static void initial_block(void)
{
  if (!nemu_md_block) return;
  size_t size;
  const uint8_t *disk = nemu_block_image(&size);
  static const uint8_t zero[4096];
  if (size > NEMU_JOURNAL_BLOCK_MAX_IMAGE || (size && !disk)) {
    fail("BLOCK image exceeds supported 16 GiB profile");
    return;
  }
  block_image_size = size;
  for (size_t offset = 0; offset < size; offset += sizeof(zero)) {
    size_t length = size - offset < sizeof(zero) ? size - offset : sizeof(zero);
    block_pages += memcmp(disk + offset, zero, length) != 0;
  }
  uint64_t geometry[] = {size, block_pages};
  append(JOURNAL_BLOCK_IMAGE, 0, geometry, sizeof(geometry));
  for (uint64_t offset = 0; offset < size && !failed; offset += sizeof(zero)) {
    size_t length = size - offset < sizeof(zero) ? size - offset : sizeof(zero);
    if (memcmp(disk + offset, zero, length))
      append_parts(JOURNAL_BLOCK_PAGE, 0, &offset, sizeof(offset), disk + offset, length);
  }
}

void nemu_journal_init(void)
{
  if (!nemu_journal_requested()) return;
  load_inputs(nemu_plic_input_path, "PLIC", inputs, &input_count, 1, 32);
  load_inputs(nemu_uart_input_path, "UART", uart_inputs, &uart_input_count, 0, 255);
  if (nemu_md_block && (!nemu_block_reset_state || !nemu_block_image || !nemu_block_reset_state())) {
    fprintf(stderr, "NEMU BLOCK capture requires reset peripheral state\n");
    exit(EXIT_FAILURE);
  }
  if (nemu_md_net && (!nemu_net_reset_state || !nemu_net_reset_state())) {
    fprintf(stderr, "NEMU NET capture requires reset peripheral state\n");
    exit(EXIT_FAILURE);
  }
  if (nemu_md_rng && (!nemu_rng_reset_state || !nemu_rng_reset_state())) {
    fprintf(stderr, "NEMU RNG capture requires reset peripheral state\n");
    exit(EXIT_FAILURE);
  }
  if (nemu_md_uart && (!nemu_uart_reset_state || !nemu_uart_reset_state())) {
    fprintf(stderr, "NEMU UART capture requires reset peripheral state\n");
    exit(EXIT_FAILURE);
  }
  if (nemu_md_plic && (!nemu_plic_reset_state || !nemu_plic_reset_state())) {
    fprintf(stderr, "NEMU PLIC capture requires reset peripheral state\n");
    exit(EXIT_FAILURE);
  }
  nemu_md_harts = nemu_nr_harts;
  uint16_t endian = 1;
  if (*(uint8_t *)&endian != 1) {
    fprintf(stderr, "NEMU journal requires a little-endian host\n");
    exit(EXIT_FAILURE);
  }
  if (nemu_journal_fd >= 0) {
    struct stat info;
    int flags = fcntl(nemu_journal_fd, F_GETFL);
    if (flags < 0 || (flags & O_ACCMODE) != O_WRONLY || (flags & O_NONBLOCK) ||
        fstat(nemu_journal_fd, &info) || !S_ISFIFO(info.st_mode)) {
      fprintf(stderr, "NEMU stream requires a blocking write-only pipe descriptor\n");
      exit(EXIT_FAILURE);
    }
    struct sigaction action = {.sa_handler = SIG_IGN};
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGPIPE, &action, &previous_sigpipe)) {
      perror("NEMU stream SIGPIPE setup");
      exit(EXIT_FAILURE);
    }
    int descriptor = fcntl(nemu_journal_fd, F_DUPFD_CLOEXEC, 3);
    if (descriptor >= 0) {
      journal = fdopen(descriptor, "wb");
      if (!journal) close(descriptor);
    }
    if (!nemu_journal_limit_explicit) nemu_journal_max_bytes = UINT64_MAX;
  } else {
    journal = fopen(nemu_journal_path, "wbx");
  }
  if (!journal) {
    perror("NEMU journal open (refuses to overwrite files)");
    exit(EXIT_FAILURE);
  }
  if (setvbuf(journal, journal_buffer, _IOFBF, sizeof(journal_buffer))) {
    fprintf(stderr, "NEMU journal buffer setup failed\n");
    exit(EXIT_FAILURE);
  }
  const NemuJournalHeader header = {NEMU_JOURNAL_MAGIC,
      nemu_md_block ? NEMU_JOURNAL_BLOCK_VERSION : nemu_md_net ? NEMU_JOURNAL_NET_VERSION : nemu_md_rng ? NEMU_JOURNAL_RNG_VERSION : nemu_md_tlb_retain ? NEMU_JOURNAL_TLB_VERSION : (nemu_md_uart ? NEMU_JOURNAL_UART_VERSION : (nemu_md_plic ? NEMU_JOURNAL_PLIC_VERSION :
      (nemu_md_clint ? NEMU_JOURNAL_CLINT_VERSION :
      (nemu_md_interrupts ? NEMU_JOURNAL_IRQ_VERSION : NEMU_JOURNAL_VERSION)))) |
      (riscv_v128_preview_enabled() ? NEMU_JOURNAL_VECTOR_FLAG : 0), XLEN,
      nemu_nr_harts, PMEM_LEFT, CONFIG_MSIZE, nemu_md_features(), nemu_threaded};
  if (fwrite(&header, sizeof(header), 1, journal) != 1) fail("header write error");
  initial_block();
  initial_memory(PMEM_LEFT, CONFIG_MSIZE);
  if (in_rom(CONFIG_ROM_BASE)) initial_memory(CONFIG_ROM_BASE, CONFIG_ROM_SIZE);
  for (unsigned hart = 0; hart < nemu_nr_harts; hart++) {
    cpu_select_hart(hart);
    nemu_md_capture(&previous[hart]);
    if (riscv_v128_preview_enabled())
      memcpy(previous_vector[hart].reg, cpu.vreg, sizeof(cpu.vreg));
    if (nemu_md_clint && (previous[hart].mtimecmp != UINT64_MAX || previous[hart].stip ||
        previous[hart].seip || (previous[hart].csr[CSR_MIP] & 0x88)))
      fail("CLINT capture requires reset peripheral state");
    if (nemu_md_plic && (previous[hart].csr[CSR_MIP] & 0x800))
      fail("PLIC capture requires clear MEIP");
    append_parts(JOURNAL_STATE, hart, &previous[hart], sizeof(NemuDiffState),
                 riscv_v128_preview_enabled() ? &previous_vector[hart] : NULL,
                 riscv_v128_preview_enabled() ? sizeof(NemuDiffVectorState) : 0);
  }
  cpu_select_hart(0);
  if (failed) exit(EXIT_FAILURE);
  nemu_md_enabled = true;
  printf("NEMU_JOURNAL enabled harts=%u backend=%s\n", nemu_nr_harts, nemu_threaded ? "threaded" : "rr");
}

bool nemu_journal_begin(void)
{
  if (!journal) return true;
  participating = true;
  cpu_bus_lock();
  if (nemu_state.state != NEMU_RUNNING) {
    cpu_bus_unlock();
    return false;
  }
  if (!nemu_md_interrupts && riscv_intr_may_pending()) {
    fail("unsupported pending interrupt");
    cpu_bus_unlock();
    return false;
  }
  executing = true;
  nemu_md_reset_frame();
  uint64_t pc = cpu.pc;
  append(JOURNAL_BEGIN, nemu_hartid, &pc, sizeof(pc));
  bool ready = !failed;
  cpu_bus_unlock();
  return ready;
}

bool nemu_journal_interrupt(word_t cause)
{
  if (!journal) return true;
  cpu_bus_lock();
  if (!executing || !nemu_md_interrupts) {
    fail("interrupt outside enabled instruction scope");
  } else {
    uint64_t entry[] = {cause, cpu.pc};
    append(JOURNAL_INTERRUPT, nemu_hartid, entry, sizeof(entry));
    interrupts++;
  }
  bool ready = !failed;
  cpu_bus_unlock();
  return ready;
}

void nemu_journal_end(void)
{
  if (!journal || !executing) return;
  cpu_bus_lock();
  NemuDiffState state;
  nemu_md_capture(&state);
  uint64_t record[4 + 2 * (NEMU_JOURNAL_STATE_WORDS + sizeof(NemuDiffVectorState) / 8)];
  size_t count = 4;
  record[0] = cpu.inst;
  record[1] = cpu.instruction_trapped;
  record[2] = nemu_md_frame.error;
  record[3] = nemu_state.state == NEMU_END && (!nemu_threaded || nemu_stop_hart == nemu_hartid);
  count += nemu_diff_state_delta(&state, &previous[nemu_hartid], record + count);
  if (riscv_v128_preview_enabled()) {
    const uint8_t *actual = (const uint8_t *)cpu.vreg;
    uint8_t *saved = (uint8_t *)previous_vector[nemu_hartid].reg;
    for (size_t offset = 0; offset < sizeof(cpu.vreg); offset += sizeof(uint64_t)) {
      uint64_t value, old;
      memcpy(&value, actual + offset, sizeof(value));
      memcpy(&old, saved + offset, sizeof(old));
      if (value != old) {
        record[count++] = NEMU_JOURNAL_STATE_WORDS + offset / sizeof(uint64_t);
        record[count++] = value;
        memcpy(saved + offset, &value, sizeof(value));
      }
    }
  }
  append(JOURNAL_END, nemu_hartid, record, count * sizeof(uint64_t));
  instructions[nemu_hartid]++;
  retired++;
  executing = false;
  if (nemu_md_frame.error) fail("unsupported event or frame overflow");
  if (!failed && nemu_journal_progress_interval && retired % nemu_journal_progress_interval == 0) {
    fprintf(stderr, "\nNEMU_JOURNAL_PROGRESS retired=%" PRIu64 " events=%" PRIu64 " bytes=%" PRIu64,
            retired, serial, written);
    for (unsigned hart = 0; hart < nemu_nr_harts; hart++)
      fprintf(stderr, " hart%u_retired=%" PRIu64 " hart%u_pc=0x%" PRIx64,
              hart, instructions[hart], hart, previous[hart].pc);
    fputc('\n', stderr);
  }
  cpu_bus_unlock();
}

void nemu_journal_close(void)
{
  if (!journal) return;
  if (nemu_state.state == NEMU_END && input_next != input_count) fail("unconsumed PLIC input schedule");
  if (nemu_state.state == NEMU_END && uart_input_next != uart_input_count) fail("unconsumed UART input schedule");
  if (nemu_state.state == NEMU_END && nemu_md_net &&
      (!nemu_net_input_consumed || !nemu_net_input_consumed())) fail("unconsumed NET input script");
  uint64_t result[] = {nemu_state.state, nemu_state.halt_ret,
                       instructions[0], instructions[1], instructions[2], instructions[3]};
  append(JOURNAL_COMPLETE, nemu_hartid, result, sizeof(result));
  if (fflush(journal) != 0) fail("flush error");
  if (fclose(journal) != 0) fail("close error");
  journal = NULL;
  if (nemu_journal_fd >= 0 && sigaction(SIGPIPE, &previous_sigpipe, NULL)) fail("SIGPIPE restore error");
  if (nemu_state.state != NEMU_END || nemu_state.halt_ret) fail("incomplete or unsuccessful guest execution");
  if (nemu_md_uart && uart_tx) putchar('\n');
  printf("NEMU_JOURNAL events=%" PRIu64 " bytes=%" PRIu64
         " harts=%u buffer_bytes=%zu interrupts=%" PRIu64 " clocks=%" PRIu64 " io_requests=%" PRIu64
         " plic_sources=%" PRIu64 " uart_rx=%" PRIu64 " uart_irqs=%" PRIu64 " uart_tx=%" PRIu64
         " dma_reads=%" PRIu64 " dma_writes=%" PRIu64 " dma_bytes=%" PRIu64
         " rng_inputs=%" PRIu64 " rng_irqs=%" PRIu64
         " net_rx=%" PRIu64 " net_tx=%" PRIu64 " net_irqs=%" PRIu64
         " net_rx_bytes=%" PRIu64 " net_tx_bytes=%" PRIu64 " net_rx_drops=%" PRIu64
         " block_reads=%" PRIu64 " block_writes=%" PRIu64 " block_bytes=%" PRIu64 " block_irqs=%" PRIu64
         " block_image_size=%" PRIu64 " block_pages=%" PRIu64 " status=%s\n",
         serial, written, nemu_nr_harts, sizeof(journal_buffer), interrupts, clocks, io_requests, plic_sources,
         uart_rx, uart_irqs, uart_tx,
         dma_reads, dma_writes, dma_bytes, rng_inputs, rng_irqs,
         net_rx, net_tx, net_irqs, net_rx_bytes, net_tx_bytes, net_rx_drops,
         block_reads, block_writes, block_bytes, block_irqs, block_image_size, block_pages,
         failed || nemu_state.state != NEMU_END || nemu_state.halt_ret ? "FAIL" : "OK");
}
#endif

#include <isa.h>
#include <cpu/cpu.h>
#include <cpu/thread.h>
#include <cpu/multidiff.h>
#include <memory/paddr.h>
#include <device/mmio.h>
#include <device/alarm.h>
#include <pthread.h>
#include <setjmp.h>
#include "../../../nemu/src/device/rng.c"

NEMU_TLS uint64_t g_nr_guest_inst;
NEMU_TLS jmp_buf exec_jmp_buf;
NEMU_TLS int cause;
NEMUState nemu_state;
FILE *log_fp;
const char *nemu_rng_input_path;
static pthread_barrier_t phase;
static FILE *entropy;
static const paddr_t descriptors = 0x80001000;
static const paddr_t available = 0x80002000;
static const paddr_t used = 0x80003000;
static const paddr_t output = 0x80004000;

void init_map(void);
void init_timer(void);
void init_intr(void);
bool log_enable(void) { return false; }
void add_alarm_handle(alarm_handler_t handler) { (void)handler; }
void soft_tlb_flush(void) {}
void device_update_slow(void) {}
void assert_fail_msg(void) { abort(); }
void nemu_memory_longjmp(int value) { (void)value; abort(); }
word_t riscv_hart_mip_value(const CPU_state *hart)
{
  return hart->sr[CSR_MIP] | (hart->seip ? 0x200 : 0);
}
word_t riscv_mip_value(void) { return riscv_hart_mip_value(&cpu); }

void set_nemu_state(int state, vaddr_t pc, int halt_ret)
{
  cpu_bus_lock();
  nemu_stop_hart = nemu_hartid;
  nemu_state.halt_pc = pc;
  nemu_state.halt_ret = halt_ret;
  nemu_state.state = state;
  cpu_thread_wake();
  cpu_bus_unlock();
}

static void seed_entropy(size_t size)
{
  uint8_t bytes[4096];
  assert(size <= sizeof(bytes));
  for (size_t index = 0; index < size; index++) bytes[index] = index;
  assert(ftruncate(host_random_fd, 0) == 0);
  assert(lseek(host_random_fd, 0, SEEK_SET) == 0);
  assert(write(host_random_fd, bytes, size) == (ssize_t)size);
  assert(lseek(host_random_fd, 0, SEEK_SET) == 0);
}

static void reg_write(unsigned offset, uint32_t value)
{
  paddr_write(CONFIG_RNG_MMIO + offset, 4, value);
}

static void prepare_queue(unsigned count)
{
  reg_write(0x70, 0);
  memset(guest_to_host(descriptors), 0, 0x4000);
  reg_write(0x38, 4);
  reg_write(0x80, descriptors);
  reg_write(0x90, available);
  reg_write(0xa0, used);
  reg_write(0x44, 1);
  reg_write(0x70, 4);
  for (unsigned index = 0; index < count; index++) {
    virtq_desc_t descriptor = {output + 64 * index, 8, VRING_DESC_F_WRITE, 0};
    assert(paddr_dma_write(descriptors + sizeof(descriptor) * index, &descriptor, sizeof(descriptor)));
    paddr_write(available + 4 + 2 * index, 2, index);
  }
  paddr_write(available + 2, 2, count);
  seed_entropy(4096);
}

static void test_dma(void)
{
  uint64_t value = UINT64_C(0x1122334455667788), copied = 0;
  assert(paddr_dma_read(UINT64_MAX, NULL, 0));
  assert(paddr_dma_write(UINT64_MAX, NULL, 0));
  assert(paddr_dma_write(output, &value, sizeof(value)));
  assert(paddr_dma_read(output, &copied, sizeof(copied)) && copied == value);
  for (unsigned index = 0; index < nemu_nr_harts; index++) {
    riscv_hart(index)->reservation = output;
    riscv_hart(index)->reservation_bytes = 8;
  }
  assert(!paddr_dma_write(output + (UINT64_C(1) << 32), &value, sizeof(value)));
  assert(!paddr_dma_read(output + (UINT64_C(1) << 32), &copied, sizeof(copied)));
  assert(!paddr_dma_write(PMEM_RIGHT, &value, sizeof(value)));
  assert(!paddr_dma_read(UINT64_MAX - 3, &copied, sizeof(copied)));
  assert(!paddr_dma_read(output, &copied, SIZE_MAX));
  assert(!paddr_dma_write(output, &value, SIZE_MAX));
  assert(!paddr_dma_write(CONFIG_ROM_BASE, &value, sizeof(value)));
  assert(paddr_dma_read(CONFIG_ROM_BASE, &copied, sizeof(copied)));
  assert(paddr_dma_write(output + 8, &value, sizeof(value)));
  for (unsigned index = 0; index < nemu_nr_harts; index++)
    assert(riscv_hart(index)->reservation_bytes == 8);
  assert(paddr_dma_write(output + 7, &value, 1));
  for (unsigned index = 0; index < nemu_nr_harts; index++)
    assert(riscv_hart(index)->reservation_bytes == 0);

  const paddr_t mapped[] = {CONFIG_SRAM_BASE + 0x100, CONFIG_FLASH_BASE + 0x1000};
  uint8_t buffer[64];
  for (unsigned index = 0; index < 2; index++) {
    add_mmio_map("dma-test", mapped[index], new_space(8), 8, NULL);
    memset(guest_to_host(mapped[index] - 16), 0x73, sizeof(buffer));
    memset(buffer, 0x95, sizeof(buffer));
    assert(mmio_map_overlaps(mapped[index] - 16, sizeof(buffer)));
    assert(!mmio_map_overlaps(mapped[index] - 16, 16));
    assert(!mmio_map_overlaps(mapped[index] + 8, 16));
    assert(!paddr_dma_read(mapped[index] - 16, buffer, sizeof(buffer)));
    assert(!paddr_dma_write(mapped[index] - 16, buffer, sizeof(buffer)));
    for (unsigned offset = 0; offset < sizeof(buffer); offset++) {
      assert(buffer[offset] == 0x95);
      assert(guest_to_host(mapped[index] - 16)[offset] == 0x73);
    }
  }
  assert(mmio_map_overlaps(UINT64_MAX, 2));
  assert(!mmio_map_overlaps(UINT64_MAX, 0));
}

static void test_fail_closed(void)
{
  uint64_t stored = 42, value = 91;
  assert(paddr_dma_write(output, &stored, sizeof(stored)));
  cpu.reservation = output;
  cpu.reservation_bytes = 8;
  nemu_md_enabled = true;
  for (unsigned write = 0; write < 2; write++) {
    nemu_state.state = NEMU_RUNNING;
    nemu_md_frame.error = 0;
    bool accepted = write ? paddr_dma_write(output, &value, sizeof(value))
                          : paddr_dma_read(output, &value, sizeof(value));
    assert(!accepted && value == 91);
    assert(nemu_md_frame.error && nemu_state.state == NEMU_ABORT && nemu_state.halt_ret == 1);
    assert(cpu.reservation_bytes == 8);
    assert(!memcmp(guest_to_host(output), &stored, sizeof(stored)));
  }
  nemu_md_enabled = false;
  nemu_md_frame.error = 0;
  nemu_state.state = NEMU_RUNNING;
}

static void test_rng_failures(void)
{
  uint16_t head = 0x1234;
  prepare_queue(1);
  rng.driver_addr = PMEM_RIGHT;
  assert(!queue_pop(&head) && head == 0x1234 && rng.last_avail_idx == 0);
  rng.driver_addr = PMEM_RIGHT - 3;
  paddr_write(PMEM_RIGHT - 1, 2, 1);
  assert(!queue_pop(&head) && head == 0x1234 && rng.last_avail_idx == 0);
  prepare_queue(1);
  paddr_write(available + 4, 2, 4);
  assert(!queue_pop(&head) && rng.last_avail_idx == 1);

  const paddr_t bad_used[] = {PMEM_RIGHT, PMEM_RIGHT - 3, PMEM_RIGHT - 7};
  for (unsigned index = 0; index < 3; index++) {
    prepare_queue(1);
    rng.device_addr = bad_used[index];
    memset(guest_to_host(PMEM_RIGHT - 15), 0, 16);
    assert(!queue_push(0, 8) && !rng.interrupt_status);
    if (index) assert(paddr_read(bad_used[index] + 2, 2) == 0);
  }

  prepare_queue(2);
  rng.device_addr = PMEM_RIGHT;
  reg_write(0x50, 0);
  assert(rng.last_avail_idx == 1 && !rng.interrupt_status);
  assert(guest_to_host(output + 64)[0] == 0);

  prepare_queue(1);
  virtq_desc_t descriptor = {output, 300, VRING_DESC_F_WRITE, 0};
  assert(paddr_dma_write(descriptors, &descriptor, sizeof(descriptor)));
  memset(guest_to_host(output), 0xa5, 300);
  seed_entropy(270);
  reg_write(0x50, 0);
  assert(paddr_read(used + 8, 4) == 256);
  assert(paddr_read(used + 2, 2) == 1 && rng.interrupt_status == 1);
  for (unsigned index = 0; index < 300; index++)
    assert(guest_to_host(output)[index] == (index < 256 ? (uint8_t)index : 0xa5));

  prepare_queue(1);
  descriptor = (virtq_desc_t){output, 8, VRING_DESC_F_WRITE | VRING_DESC_F_NEXT, 0};
  assert(paddr_dma_write(descriptors, &descriptor, sizeof(descriptor)));
  assert(fill_desc_chain(0) == 32);
  descriptor.flags = 0;
  assert(paddr_dma_write(descriptors, &descriptor, sizeof(descriptor)));
  assert(fill_desc_chain(0) == 0);
  rng.desc_addr = PMEM_RIGHT;
  assert(fill_desc_chain(0) == 0);
}

static void test_rng_chain(void)
{
  prepare_queue(1);
  virtq_desc_t chain[] = {{output, 300, VRING_DESC_F_WRITE | VRING_DESC_F_NEXT, 1},
                        {output + 300, 9, VRING_DESC_F_WRITE, 0}};
  assert(paddr_dma_write(descriptors, chain, sizeof(chain)));
  reg_write(0x50, 0);
  assert(paddr_read(used + 8, 4) == 309 && paddr_read(used + 2, 2) == 1);
  for (unsigned index = 0; index < 309; index++)
    assert(guest_to_host(output)[index] == (uint8_t)index);
  assert(paddr_read(CONFIG_PLIC_MMIO + 0x1000, 4) & (1u << CONFIG_RNG_PLIC_IRQ));
  reg_write(0x64, 1);
  assert(!rng.interrupt_status);
  reg_write(0x70, 0);
  assert(!rng.queue_ready && !rng.queue_num && !rng.last_avail_idx);

  prepare_queue(1);
  rng.last_avail_idx = UINT16_MAX;
  paddr_write(available + 2, 2, 0);
  paddr_write(available + 4 + 3 * 2, 2, 0);
  paddr_write(used + 2, 2, UINT16_MAX);
  reg_write(0x50, 0);
  assert(rng.last_avail_idx == 0 && paddr_read(used + 2, 2) == 0);
  assert(paddr_read(used + 4 + 3 * 8 + 4, 4) == 8);
}

static void rendezvous(void)
{
  int result = pthread_barrier_wait(&phase);
  assert(result == 0 || result == PTHREAD_BARRIER_SERIAL_THREAD);
}

static void threaded(uint64_t count)
{
  (void)count;
  for (unsigned round = 0; round < 100; round++) {
    if (!nemu_hartid) {
      cpu_bus_lock();
      prepare_queue(nemu_nr_harts);
      cpu_bus_unlock();
    }
    rendezvous();
    cpu_bus_lock();
    cpu.reservation = output + 64 * nemu_hartid;
    cpu.reservation_bytes = 8;
    cpu_bus_unlock();
    rendezvous();
    reg_write(0x50, 0);
    rendezvous();
    cpu_bus_lock();
    assert(cpu.reservation_bytes == 0);
    assert(paddr_read(used + 2, 2) == nemu_nr_harts);
    assert(rng.last_avail_idx == nemu_nr_harts);
    for (unsigned index = 0; index < 8; index++)
      assert(guest_to_host(output + 64 * nemu_hartid)[index] == 8 * nemu_hartid + index);
    cpu_bus_unlock();
    rendezvous();
  }
  g_nr_guest_inst = 100;
  rendezvous();
  if (!nemu_hartid) set_nemu_state(NEMU_END, 0, 0);
}

int main(int argc, char **argv)
{
  assert(argc == 2);
  nemu_nr_harts = strtoul(argv[1], NULL, 10);
  assert(nemu_nr_harts == 1 || nemu_nr_harts == 2 || nemu_nr_harts == 4);
  nemu_threaded = true;
  for (unsigned index = 0; index < nemu_nr_harts; index++) {
    riscv_hart(index)->sr[CSR_MHARTID] = index;
    riscv_hart(index)->mtimecmp = UINT64_MAX;
  }
  entropy = tmpfile();
  assert(entropy);
  host_random_fd = dup(fileno(entropy));
  assert(host_random_fd >= 0);
  init_map();
  init_timer();
  init_intr();
  init_rng();
  cpu_bus_lock();
  fprintf(stderr, "NEMU_DMA_RNG_PHASE dma\n");
  test_dma();
  fprintf(stderr, "NEMU_DMA_RNG_PHASE fail-closed\n");
  test_fail_closed();
  fprintf(stderr, "NEMU_DMA_RNG_PHASE queue-failures\n");
  test_rng_failures();
  fprintf(stderr, "NEMU_DMA_RNG_PHASE chains\n");
  test_rng_chain();
  cpu_bus_unlock();
  fprintf(stderr, "NEMU_DMA_RNG_PHASE threaded\n");
  assert(pthread_barrier_init(&phase, NULL, nemu_nr_harts) == 0);
  cpu_threads_run(threaded);
  assert(nemu_state.state == NEMU_END && g_nr_guest_inst == 100 * nemu_nr_harts);
  assert(pthread_barrier_destroy(&phase) == 0);
  assert(close(host_random_fd) == 0);
  assert(fclose(entropy) == 0);
  printf("NEMU_DMA_RNG_PASS RV%d harts=%u rounds=100\n", XLEN, nemu_nr_harts);
  return 0;
}

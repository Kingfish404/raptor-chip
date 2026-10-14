#include <isa.h>
#include <cpu/cpu.h>
#include <cpu/thread.h>
#include <memory/paddr.h>
#include <device/alarm.h>
#include <pthread.h>
#include <setjmp.h>
#include <stdio.h>
#include <stdatomic.h>

NEMU_TLS uint64_t g_nr_guest_inst;
NEMU_TLS jmp_buf exec_jmp_buf;
NEMU_TLS int cause;
NEMUState nemu_state;
FILE *log_fp;
static pthread_barrier_t phase;
static atomic_uint claims;
static atomic_uint completed;

void init_map(void);
void init_timer(void);
void init_intr(void);
void clint_update_mip(void);
void plic_raise_irq(int irq);

bool log_enable(void) { return false; }
void add_alarm_handle(alarm_handler_t handler) { (void)handler; }
void soft_tlb_flush(void) {}
void device_update_slow(void) {}
void assert_fail_msg(void) { abort(); }
word_t riscv_hart_mip_value(const CPU_state *hart)
{
  return hart->sr[CSR_MIP] | (hart->seip ? 0x200 : 0);
}
word_t riscv_mip_value(void) { return riscv_hart_mip_value(&cpu); }

void set_nemu_state(int state, vaddr_t pc, int halt_ret)
{
  cpu_bus_lock();
  nemu_state.halt_pc = pc;
  nemu_state.halt_ret = halt_ret;
  nemu_state.state = state;
  cpu_thread_wake();
  cpu_bus_unlock();
}

static void rendezvous(void)
{
  int result = pthread_barrier_wait(&phase);
  assert(result == 0 || result == PTHREAD_BARRIER_SERIAL_THREAD);
}

static void exercise(uint64_t count)
{
  (void)count;
  const paddr_t shared = PMEM_LEFT + 0x10000;
  paddr_t enable = CONFIG_PLIC_MMIO + 0x2000 + 2 * nemu_hartid * 0x80;
  paddr_t claim = CONFIG_PLIC_MMIO + 0x200004 + 2 * nemu_hartid * 0x1000;
  paddr_write(enable, 4, 2);
  if (nemu_hartid == 0) paddr_write(CONFIG_PLIC_MMIO + 4, 4, 1);
  rendezvous();
  for (unsigned round = 0; round < 200; round++)
  {
    if (nemu_hartid == 0)
    {
      atomic_store(&claims, 0);
      plic_raise_irq(1);
    }
    rendezvous();
    word_t source = paddr_read(claim, 4);
    assert(source <= 1);
    atomic_fetch_add(&claims, source);
    rendezvous();
    assert(atomic_load(&claims) == 1);
    paddr_write(claim, 4, source);
    rendezvous();
  }
  for (unsigned iteration = 0; iteration < 5000; iteration++)
  {
    cpu_bus_lock();
    word_t value = paddr_read(shared, 4);
    paddr_write(shared, 4, value + 1);
    cpu_bus_unlock();
    uint64_t dma_value = iteration;
    assert(paddr_dma_write(shared + 64, &dma_value, sizeof(dma_value)));
    (void)paddr_read(shared + 68, 4);
    uint8_t byte = iteration;
    assert(paddr_dma_read(shared + 64, &byte, 1));
    paddr_write(shared + 71, 1, byte);
  }
  rendezvous();
  assert(paddr_read(shared, 4) == 5000 * nemu_nr_harts);
  cpu_bus_lock();
  cpu.reservation = shared + 128;
  cpu.reservation_bytes = 8;
  cpu_bus_unlock();
  rendezvous();
  if (nemu_hartid == 0)
  {
    uint8_t byte = 7;
    assert(paddr_dma_write(shared + 136, &byte, 1));
  }
  rendezvous();
  cpu_bus_lock();
  assert(cpu.reservation_bytes == 8);
  cpu_bus_unlock();
  rendezvous();
  if (nemu_hartid == 0)
  {
    uint8_t byte = 7;
    assert(paddr_dma_write(shared + 135, &byte, 1));
  }
  rendezvous();
  cpu_bus_lock();
  assert(cpu.reservation_bytes == 0);
  cpu_bus_unlock();
  if (nemu_setjmp(exec_jmp_buf) == 0)
  {
    cpu_bus_lock();
    cpu_bus_lock();
    nemu_longjmp(exec_jmp_buf, 1);
  }
  cpu_bus_unwind();
  rendezvous();
  unsigned target = (nemu_hartid + 1) % nemu_nr_harts;
  paddr_write(CONFIG_RTC_MMIO_CLINT + 4 * target, 4, 1);
  rendezvous();
  cpu.sr[CSR_MIE] = 8;
  cpu.sr[CSR_MSTATUS] = 0;
  nemu_hart_waiting[nemu_hartid] = true;
  assert(cpu_thread_poll());
  assert(cpu.sr[CSR_MIP] & 8);
  paddr_write(CONFIG_RTC_MMIO_CLINT + 4 * nemu_hartid, 4, 0);
  rendezvous();
  g_nr_guest_inst = 5000;
  if (atomic_fetch_add(&completed, 1) + 1 == nemu_nr_harts)
    set_nemu_state(NEMU_END, 0, 0);
}

int main(int argc, char **argv)
{
  assert(argc == 2);
  nemu_nr_harts = strtoul(argv[1], NULL, 10);
  assert(nemu_nr_harts >= 2 && nemu_nr_harts <= 4);
  nemu_threaded = true;
  for (unsigned hartid = 0; hartid < nemu_nr_harts; hartid++)
  {
    riscv_hart(hartid)->mtimecmp = UINT64_MAX;
    riscv_hart(hartid)->sr[0x14d] = ~(word_t)0;
    riscv_hart(hartid)->sr[0x15d] = ~(word_t)0;
  }
  init_map();
  init_timer();
  init_intr();
  assert(pthread_barrier_init(&phase, NULL, nemu_nr_harts) == 0);
  nemu_state.state = NEMU_RUNNING;
  cpu_threads_run(exercise);
  assert(nemu_state.state == NEMU_END);
  assert(g_nr_guest_inst == 5000 * nemu_nr_harts);
  assert(pthread_barrier_destroy(&phase) == 0);
  printf("NEMU_THREADED_BUS_PASS RV%d harts=%u\n", XLEN, nemu_nr_harts);
}

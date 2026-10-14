#include <isa.h>
#include <cpu/cpu.h>
#include <device/map.h>
#include <device/alarm.h>
#include <stdio.h>

NEMU_TLS uint64_t g_nr_guest_inst;
NEMUState nemu_state;
static IOMap maps[8];
static unsigned map_count;
static unsigned flushes;
static unsigned polls;

void init_timer(void);
void init_intr(void);
void clint_update_mip(void);
bool clint_wfi_advance(void);
void plic_raise_irq(int irq);
bool pmp_check(paddr_t, int, uint32_t, bool, bool, bool);
int pmp_csr_write(uint16_t, word_t);

uint64_t get_time(void) { return g_nr_guest_inst / 1000; }
void add_alarm_handle(alarm_handler_t handler) { (void)handler; }
void soft_tlb_flush(void) { flushes++; }
void device_update_slow(void) { polls++; }
void assert_fail_msg(void) { abort(); }

word_t riscv_hart_mip_value(const CPU_state *hart)
{
  return hart->sr[CSR_MIP] | (hart->seip ? 0x200 : 0);
}
word_t riscv_mip_value(void) { return riscv_hart_mip_value(&cpu); }

uint8_t *new_space(int size)
{
  uint8_t *space = calloc(1, size);
  assert(space);
  return space;
}

void add_mmio_map(const char *name, paddr_t addr, void *space, uint32_t len, io_callback_t callback)
{
  assert(map_count < 8);
  maps[map_count++] = (IOMap){name, addr, addr + len - 1, space, callback};
}

static uint64_t access_mmio(paddr_t addr, unsigned len, bool write, uint64_t value)
{
  for (unsigned index = 0; index < map_count; index++)
  {
    IOMap *map = &maps[index];
    if (addr < map->low || addr + len - 1 > map->high)
      continue;
    uint8_t *bytes = (uint8_t *)map->space + addr - map->low;
    if (write)
      memcpy(bytes, &value, len);
    map->callback(addr - map->low, len, write);
    value = 0;
    memcpy(&value, bytes, len);
    return value;
  }
  abort();
}

static void write32(paddr_t addr, uint32_t value) { access_mmio(addr, 4, true, value); }
static uint32_t read32(paddr_t addr) { return access_mmio(addr, 4, false, 0); }

static void check_clint(unsigned harts)
{
  for (unsigned target = 0; target < harts; target++)
  {
    cpu_select_hart((target + 1) % harts);
    write32(CONFIG_RTC_MMIO_CLINT + 4 * target, 3);
    assert(read32(CONFIG_RTC_MMIO_CLINT + 4 * target) == 1);
    for (unsigned hartid = 0; hartid < harts; hartid++)
      assert(!!(riscv_hart(hartid)->sr[CSR_MIP] & 8) == (hartid == target));
    write32(CONFIG_RTC_MMIO_CLINT + 4 * target, 0);
    paddr_t comparator = CONFIG_RTC_MMIO_CLINT + 0x4000 + 8 * target;
    write32(comparator, 500 + target);
    write32(comparator + 4, 0);
    assert(riscv_hart(target)->mtimecmp == 500 + target);
  }
  g_nr_guest_inst = 50100;
  clint_update_mip();
  for (unsigned hartid = 0; hartid < harts; hartid++)
  {
    assert(!!(riscv_hart(hartid)->sr[CSR_MIP] & 0x80) == (hartid <= 1));
    assert(riscv_hart(hartid)->sr[CSR_TIME] == 501);
  }
  for (unsigned hartid = 0; hartid < harts; hartid++)
  {
    riscv_hart(hartid)->mtimecmp = UINT64_MAX;
    riscv_hart(hartid)->sr[CSR_MIE] = 0;
  }
  assert(!clint_wfi_advance());
  assert(g_nr_guest_inst == 50100);
  riscv_hart(0)->mtimecmp = 600;
  riscv_hart(harts - 1)->mtimecmp = 700;
  riscv_hart(harts - 1)->sr[CSR_MIE] = 0x80;
  assert(clint_wfi_advance());
  assert(g_nr_guest_inst == 70000);
  assert(riscv_hart(harts - 1)->sr[CSR_MIP] & 0x80);
  riscv_hart(harts - 1)->sr[CSR_MIE] = 0;
}

static void check_plic(unsigned harts)
{
  for (unsigned context = 0; context < harts * 2; context++)
  {
    unsigned source = context + 1;
    paddr_t enable = CONFIG_PLIC_MMIO + 0x2000 + context * 0x80;
    paddr_t claim = CONFIG_PLIC_MMIO + 0x200004 + context * 0x1000;
    write32(CONFIG_PLIC_MMIO + source * 4, 1);
    write32(enable, 1u << source);
    plic_raise_irq(source);
    for (unsigned hartid = 0; hartid < harts; hartid++)
    {
      assert(!!(riscv_hart(hartid)->sr[CSR_MIP] & 0x800) ==
             (hartid == context / 2 && !(context & 1)));
      assert(riscv_hart(hartid)->seip == (hartid == context / 2 && (context & 1)));
    }
    assert(read32(claim) == source);
    assert(read32(claim) == 0);
    write32(claim, source);
    write32(enable, 0);
  }
  write32(CONFIG_PLIC_MMIO + 32 * 4, 1);
  write32(CONFIG_PLIC_MMIO + 0x2004, 1);
  plic_raise_irq(32);
  assert(read32(CONFIG_PLIC_MMIO + 0x200004) == 32);
  write32(CONFIG_PLIC_MMIO + 0x2004, 0);
  write32(CONFIG_PLIC_MMIO + 0x2000, 2);
  write32(CONFIG_PLIC_MMIO + 0x2080, 2);
  plic_raise_irq(1);
  assert(read32(CONFIG_PLIC_MMIO + 0x200004) == 1);
  assert(read32(CONFIG_PLIC_MMIO + 0x201004) == 0);
  write32(CONFIG_PLIC_MMIO + 0x2000, 0);
  write32(CONFIG_PLIC_MMIO + 0x2080, 0);
}

static void check_hart_state(unsigned harts)
{
  for (unsigned hartid = 0; hartid < harts; hartid++)
  {
    cpu_select_hart(hartid);
    cpu.gpr[10] = 0x100 + hartid;
    cpu.fpr[0] = 0x200 + hartid;
    cpu.sr[CSR_SATP] = 0x300 + hartid;
    cpu.reservation = 0x80001000;
    cpu.reservation_bytes = 8;
    pmp_csr_write(CSR_PMPADDR0, 0x80001000 >> 2);
    pmp_csr_write(CSR_PMPCFG0, hartid & 1 ? 0x10 : 0x11);
  }
  for (unsigned repeat = 0; repeat < 4; repeat++)
    for (unsigned hartid = 0; hartid < harts; hartid++)
    {
      cpu_select_hart(hartid);
      assert(cpu.gpr[10] == 0x100 + hartid && cpu.fpr[0] == 0x200 + hartid);
      assert(cpu.sr[CSR_SATP] == 0x300 + hartid);
      assert(pmp_check(0x80001000, 4, PRV_S, true, false, false) == (hartid & 1));
    }
  assert(flushes >= 4 * harts);
  cpu_invalidate_reservations(0x80001008, 1);
  for (unsigned hartid = 0; hartid < harts; hartid++)
    assert(riscv_hart(hartid)->reservation_bytes == 8);
  cpu_invalidate_reservations(0x80001007, 1);
  for (unsigned hartid = 0; hartid < harts; hartid++)
    assert(riscv_hart(hartid)->reservation_bytes == 0);
}

static void check_scheduler(unsigned harts)
{
  nemu_state.state = NEMU_RUNNING;
  unsigned executed[4] = {0};
  for (unsigned step = 0; step < harts * 512; step++)
  {
    assert(cpu_schedule());
    executed[nemu_hartid]++;
  }
  for (unsigned hartid = 0; hartid < harts; hartid++)
  {
    assert(executed[hartid] == 512);
    nemu_hart_waiting[hartid] = true;
    riscv_hart(hartid)->mtimecmp = UINT64_MAX;
    riscv_hart(hartid)->sr[CSR_MIE] = 8;
  }
  unsigned runnable = (nemu_hartid + 1) % harts;
  nemu_hart_waiting[runnable] = false;
  riscv_hart(nemu_hartid)->mtimecmp = 900;
  riscv_hart(nemu_hartid)->sr[CSR_MIE] = 0x80;
  assert(cpu_schedule());
  assert(nemu_hartid == runnable && g_nr_guest_inst == 70000 && polls == 0);
  nemu_hart_waiting[runnable] = true;
  for (unsigned hartid = 0; hartid < harts; hartid++)
  {
    riscv_hart(hartid)->mtimecmp = UINT64_MAX;
    riscv_hart(hartid)->sr[CSR_MIE] = 8;
  }
  unsigned target = (nemu_hartid + 1) % harts;
  write32(CONFIG_RTC_MMIO_CLINT + 4 * target, 1);
  assert(cpu_schedule());
  assert(nemu_hartid == target && !nemu_hart_waiting[target]);
  assert(polls == 0);
  write32(CONFIG_RTC_MMIO_CLINT + 4 * target, 0);
  nemu_hart_waiting[target] = true;
  riscv_hart(target)->sr[CSR_MIE] = 0x80;
  riscv_hart(target)->mtimecmp = 1000;
  assert(cpu_schedule());
  assert(nemu_hartid == target && g_nr_guest_inst == 100000 && polls == 1);
}

int main(int argc, char **argv)
{
  assert(argc == 2);
  nemu_nr_harts = strtoul(argv[1], NULL, 10);
  assert(nemu_nr_harts >= 2 && nemu_nr_harts <= 4);
  for (unsigned hartid = 0; hartid < nemu_nr_harts; hartid++)
  {
    riscv_hart(hartid)->mtimecmp = UINT64_MAX;
    riscv_hart(hartid)->sr[0x14d] = ~(word_t)0;
    riscv_hart(hartid)->sr[0x15d] = ~(word_t)0;
  }
  init_timer();
  init_intr();
  check_clint(nemu_nr_harts);
  check_plic(nemu_nr_harts);
  check_hart_state(nemu_nr_harts);
  check_scheduler(nemu_nr_harts);
  for (unsigned index = 0; index < map_count; index++)
    free(maps[index].space);
  printf("RV%d %u-hart CLINT/PLIC/PMP/scheduler: PASS\n", XLEN, nemu_nr_harts);
  return 0;
}

#include <stdint.h>
#include <common.h>
#include <utils.h>
#include <verilated.h>
#include <inttypes.h>
#include <stdlib.h>
#include <string.h>

void difftest_skip_ref();
void npc_abort();

extern NPCState npc;
extern VerilatedContext *contextp;

// QEMU virt finisher (sifive,test) constants
#define FINISHER_BASE 0x100000
#define FINISHER_SIZE 0x1000
#define FINISHER_PASS 0x5555
#define FINISHER_FAIL 0x3333
#define FINISHER_RESET 0x7777

#define CLINT_BASE 0x02000000u
#define CLINT_SIZE 0x000c0000u
#define PLIC_BASE 0x0c000000u
#define PLIC_SIZE 0x01000000u
#define NS16550_BASE 0x10000000u
#define NS16550_SIZE 0x100u
#define VIRTIO_BLK_BASE 0x10001000u
#define VIRTIO_BLK_SIZE 0x1000u
#define LITEUART_BASE 0x10011800u
#define LITEUART_SIZE 0x100u
#define QEMU_SDHCI_PCI_ECAM_BASE 0x30008000u
#define QEMU_SDHCI_PCI_ECAM_SIZE 0x1000u
#define QEMU_SDHCI_BASE 0x40000000u
#define QEMU_SDHCI_SIZE 0x100u

static struct
{
  uint8_t pmem[MSIZE];
  uint8_t sdram[SDRAM_SIZE];
  uint8_t sram[SRAM_SIZE];
  uint8_t mrom[MROM_SIZE];
  uint8_t flash[FLASH_SIZE];
#ifdef CONFIG_SOFT_MMIO
  uint32_t rtc_port_base[2] = {0x0, 0x0};
#endif
} memory;

typedef struct
{
  const char *name;
  paddr_t base;
  paddr_t size;
  uint8_t *host;
  const char *desc;
} host_map_t;

typedef struct
{
  const char *name;
  paddr_t base;
  paddr_t size;
  const char *desc;
  bool skip_difftest;
  void (*handler)(paddr_t addr, word_t wdata, char wmask, bool is_write, word_t *data);
} mmio_map_t;

typedef struct
{
  const char *name;
  paddr_t base;
  paddr_t size;
  const char *desc;
} map_print_entry_t;

static paddr_t canonical_paddr(paddr_t addr)
{
#ifdef CONFIG_ISA64
  return (paddr_t)((uint32_t)addr);
#else
  return addr;
#endif
}

static host_map_t host_maps[] = {
    {"pmem", MBASE, MSIZE, memory.pmem, "main memory / QEMU virt DRAM"},
    {"sdram", SDRAM_BASE, SDRAM_SIZE, memory.sdram, "external SDRAM window"},
    {"sram", SRAM_BASE, SRAM_SIZE, memory.sram, "on-chip SRAM window"},
    {"mrom", MROM_BASE, MROM_SIZE, memory.mrom, "mask ROM / boot trampoline"},
    {"flash", FLASH_BASE, FLASH_SIZE, memory.flash, "flash image mirror"},
};

static bool map_contains(paddr_t addr, paddr_t base, paddr_t size)
{
  return addr >= base && addr < base + size;
}

static bool map_range_offset(paddr_t addr, paddr_t base, paddr_t size,
                             size_t len, size_t *offset)
{
  addr = canonical_paddr(addr);
  if (!map_contains(addr, base, size))
    return false;
  uint64_t off = (uint64_t)(addr - base);
  if (off + (uint64_t)len > (uint64_t)size)
    return false;
  if (offset != NULL)
    *offset = (size_t)off;
  return true;
}

static void report_invalid_host_access(const char *name, const char *op,
                                       uint64_t addr, size_t len)
{
  static unsigned log_count = 0;
  if (log_count < 16)
  {
    fprintf(stderr, "memory.cc: invalid %s %s at 0x%08" PRIx64 " len %zu\n",
            name, op, addr, len);
    fflush(stderr);
  }
  else if (log_count == 16)
  {
    fprintf(stderr, "memory.cc: suppressing further invalid memory access logs\n");
    fflush(stderr);
  }
  log_count++;
}

static const host_map_t *find_host_map(paddr_t addr)
{
  for (size_t i = 0; i < ARRLEN(host_maps); i++)
  {
    if (map_contains(addr, host_maps[i].base, host_maps[i].size))
      return &host_maps[i];
  }
  return NULL;
}

static void finisher_handle(paddr_t addr, word_t wdata, char wmask, bool is_write, word_t *data)
{
  (void)wmask;
  (void)data;
  if (is_write && (addr == FINISHER_BASE))
  {
    uint32_t val = (uint32_t)wdata;
    uint16_t cmd = val & 0xffff;
    if (cmd == FINISHER_PASS)
    {
      Log("Finisher: poweroff (0x%x)", val);
      contextp->gotFinish(true);
      npc.host_exit_ok = 1;
      npc.state = NPC_END;
    }
    else if (cmd == FINISHER_FAIL)
    {
      Log("Finisher: fail (0x%x)", val);
      npc.host_exit_ok = 0;
      npc_abort();
    }
    else if (cmd == FINISHER_RESET)
    {
      Log("Finisher: reset requested (0x%x) -- not supported, aborting", val);
      npc.host_exit_ok = 0;
      npc_abort();
    }
  }
}

static void serial_handle(paddr_t addr, word_t wdata, char wmask, bool is_write, word_t *data)
{
  (void)wmask;
  void mmio_serial_handle(paddr_t addr, word_t wdata, bool is_write, word_t *data);
  mmio_serial_handle(addr - NS16550_BASE, wdata, is_write, data);
}

static void virtio_blk_handle(paddr_t addr, word_t wdata, char wmask, bool is_write, word_t *data)
{
  (void)wmask;
  void mmio_virtio_blk_handle(paddr_t addr, word_t wdata, bool is_write, word_t *data);
  mmio_virtio_blk_handle(addr - VIRTIO_BLK_BASE, wdata, is_write, data);
}

static void sdhci_handle(paddr_t addr, word_t wdata, char wmask, bool is_write, word_t *data)
{
  void mmio_sdhci_handle(paddr_t addr, word_t wdata, char wmask, bool is_write, word_t *data);
  mmio_sdhci_handle(addr, wdata, wmask, is_write, data);
}

// egos-2000 HARDWARE platform peripherals (LiteX-style).
#define LITEX_SPI_HW_BASE 0xf0008000u
#define LITEX_SPI_HW_SIZE 0x100u
#define LITEX_UART_HW_BASE 0xf0001000u
#define LITEX_UART_HW_SIZE 0x100u
#define CLINT_HW_BASE 0xf0010000u
#define CLINT_HW_SIZE 0x10000u

static void litex_spi_hw_handle(paddr_t addr, word_t wdata, char wmask, bool is_write, word_t *data)
{
  void mmio_litex_spi_handle(paddr_t addr, word_t wdata, char wmask, bool is_write, word_t *data);
  mmio_litex_spi_handle(addr, wdata, wmask, is_write, data);
}

static void litex_uart_hw_handle(paddr_t addr, word_t wdata, char wmask, bool is_write, word_t *data)
{
  (void)wmask;
  void mmio_litex_uart_handle(paddr_t offset, word_t wdata, bool is_write, word_t *data);
  mmio_litex_uart_handle(addr - LITEX_UART_HW_BASE, wdata, is_write, data);
}

static mmio_map_t mmio_maps[] = {
    {"finisher", FINISHER_BASE, FINISHER_SIZE, "SiFive test / syscon poweroff", true, finisher_handle},
    {"clint", CLINT_BASE, CLINT_SIZE, "QEMU virt CLINT sink", false, NULL},
    {"plic", PLIC_BASE, PLIC_SIZE, "QEMU virt PLIC sink", false, NULL},
    {"serial_ns16550", NS16550_BASE, NS16550_SIZE, "QEMU virt NS16550 UART", false, serial_handle},
    {"virtio-blk", VIRTIO_BLK_BASE, VIRTIO_BLK_SIZE, "QEMU virtio-mmio block device", true, virtio_blk_handle},
    {"sdhci-pci-ecam", QEMU_SDHCI_PCI_ECAM_BASE, QEMU_SDHCI_PCI_ECAM_SIZE, "QEMU SDHCI PCI ECAM stub", true, sdhci_handle},
    {"sdhci", QEMU_SDHCI_BASE, QEMU_SDHCI_SIZE, "QEMU SDHCI SD-card controller", true, sdhci_handle},
    {"liteuart0", LITEUART_BASE, LITEUART_SIZE, "LiteX UART sink", false, NULL},
    // egos-2000 HARDWARE platform: LiteX SPI master driving an SD card. NEMU
    // does not model the device, so loads/stores must be skipped on REF.
    {"litex-spi", LITEX_SPI_HW_BASE, LITEX_SPI_HW_SIZE,
     "egos-2000 HARDWARE LiteX SPI SD controller", true, litex_spi_hw_handle},
    // egos-2000 HARDWARE platform: minimal LiteX UART. Skip on REF (no model in NEMU).
    {"litex-uart-hw", LITEX_UART_HW_BASE, LITEX_UART_HW_SIZE,
     "egos-2000 HARDWARE LiteX UART", true, litex_uart_hw_handle},
    // egos-2000 HARDWARE platform: CLINT alias at 0xf0010000. We don't model
    // it (the real CLINT lives at QEMU_CLINT_BASE) but accesses must be
    // silently absorbed and skipped on REF.
    {"clint-hw", CLINT_HW_BASE, CLINT_HW_SIZE,
     "egos-2000 HARDWARE CLINT alias sink", true, NULL},
};

static const mmio_map_t *find_mmio_map(paddr_t addr)
{
  for (size_t i = 0; i < ARRLEN(mmio_maps); i++)
  {
    if (map_contains(addr, mmio_maps[i].base, mmio_maps[i].size))
      return &mmio_maps[i];
  }
  return NULL;
}

static void print_map_entry(FILE *out, const char *kind, const char *name,
                            paddr_t base, paddr_t size, const char *desc)
{
  uint64_t low = (uint64_t)base;
  uint64_t high = (size == 0) ? low : low + (uint64_t)size - 1;
  fprintf(out, "  %-6s %-18s 0x%08" PRIx64 "  0x%08" PRIx64 "  0x%08" PRIx64,
          kind, name, low, high, (uint64_t)size);
  if (desc != NULL && desc[0] != '\0')
    fprintf(out, "  %s", desc);
  fprintf(out, "\n");
}

static int compare_map_print_entry(const void *lhs_ptr, const void *rhs_ptr)
{
  const map_print_entry_t *lhs = (const map_print_entry_t *)lhs_ptr;
  const map_print_entry_t *rhs = (const map_print_entry_t *)rhs_ptr;
  if (lhs->base < rhs->base)
    return -1;
  if (lhs->base > rhs->base)
    return 1;
  if (lhs->size < rhs->size)
    return -1;
  if (lhs->size > rhs->size)
    return 1;
  return strcmp(lhs->name, rhs->name);
}

static void print_map_entries_sorted(FILE *out, const char *kind,
                                     map_print_entry_t *entries, size_t count)
{
  qsort(entries, count, sizeof(entries[0]), compare_map_print_entry);
  for (size_t i = 0; i < count; i++)
    print_map_entry(out, kind, entries[i].name, entries[i].base,
                    entries[i].size, entries[i].desc);
}

void print_nsim_memory_map(FILE *out)
{
  if (out == NULL)
    out = stdout;

  fprintf(out, "Memory map (current sim build; MMIO has priority over host-backed overlays):\n");
  fprintf(out, "  %-6s %-18s %-10s  %-10s  %-10s  %s\n",
          "kind", "name", "base", "end", "size", "description");

  map_print_entry_t mem_entries[ARRLEN(host_maps)];
  for (size_t i = 0; i < ARRLEN(host_maps); i++)
  {
    mem_entries[i] = (map_print_entry_t){host_maps[i].name, host_maps[i].base,
                                         host_maps[i].size, host_maps[i].desc};
  }
  print_map_entries_sorted(out, "mem", mem_entries, ARRLEN(mem_entries));

  map_print_entry_t mmio_entries[ARRLEN(mmio_maps) + 2];
  size_t mmio_count = 0;
  for (size_t i = 0; i < ARRLEN(mmio_maps); i++)
  {
    mmio_entries[mmio_count++] = (map_print_entry_t){mmio_maps[i].name, mmio_maps[i].base,
                                                     mmio_maps[i].size, mmio_maps[i].desc};
  }
#ifdef CONFIG_SOFT_MMIO
  mmio_entries[mmio_count++] = (map_print_entry_t){"soft-rtc", RTC_ADDR_, 8,
                                                   "legacy CONFIG_SOFT_MMIO RTC"};
  mmio_entries[mmio_count++] = (map_print_entry_t){"soft-serial", SERIAL_PORT, 1,
                                                   "legacy CONFIG_SOFT_MMIO serial byte port"};
#endif
  print_map_entries_sorted(out, "mmio", mmio_entries, mmio_count);
  fprintf(out, "\n");
}

uint8_t *guest_to_host(paddr_t addr)
{
  addr = canonical_paddr(addr);
  const host_map_t *map = find_host_map(addr);
  if (map != NULL)
    return map->host + addr - map->base;
  // Assert(0, "Invalid guest address: " FMT_WORD, addr);
  return NULL;
}

uint8_t mmio_check_and_handle(
    paddr_t addr, word_t wdata, char wmask, bool is_write, word_t *data)
{
  addr = canonical_paddr(addr);
  const mmio_map_t *map = find_mmio_map(addr);
  if (map == NULL)
    return 0;

  if (map->handler != NULL)
    map->handler(addr, wdata, wmask, is_write, data);

  // NOTE: difftest_skip_ref() is intentionally NOT called here.
  //
  // In OoO, MMIO accesses fire pmem_read/pmem_write at issue/exec time,
  // long before the owning instruction commits. If we set is_skip_ref now,
  // it will be consumed by an UNRELATED earlier-program-order instruction
  // whose difftest_step() runs next, silently skipping that instruction on
  // REF and causing REF/DUT memory to diverge.
  //
  // For LOADS: RTL propagates the MMIO bit (l1d_load_is_mmio ->
  //   lsu_l1d.difftest_skip -> ROB.difftest_skip -> CMU DPI) so the skip
  //   is correctly issued at commit.
  // For STORES: see npc_difftest_mem_diff() in sdb.cc which inspects the
  //   committed store address and calls difftest_skip_ref() at commit.

  return 1;
}

// Exposed helper: returns true if `addr` is in an MMIO region whose model
// is not present in the reference ISS (NEMU).  Used by the commit-time DPI
// glue to decide whether to skip the REF step for a store.
extern "C" int mmio_addr_skip_difftest(paddr_t addr)
{
  addr = canonical_paddr(addr);
  const mmio_map_t *map = find_mmio_map(addr);
  return (map != NULL && map->skip_difftest) ? 1 : 0;
}

paddr_t host_to_guest(uint8_t *addr)
{
  uintptr_t host = (uintptr_t)addr;
  for (size_t i = 0; i < ARRLEN(host_maps); i++)
  {
    uintptr_t base = (uintptr_t)host_maps[i].host;
    uintptr_t limit = base + (uintptr_t)host_maps[i].size;
    if (host >= base && host < limit)
      return host_maps[i].base + (paddr_t)(host - base);
  }
  return MBASE + (paddr_t)(addr - memory.pmem);
}

static inline word_t host_read(void *addr, int len)
{
  switch (len)
  {
  case 1:
    return *(uint8_t *)addr;
  case 2:
    return *(uint16_t *)addr;
  case 4:
    return *(uint32_t *)addr;
  case 8:
    return *(uint64_t *)addr;
  default:
    assert(0);
  }
}

static inline void host_write(void *addr, word_t data, int len)
{
  switch (len)
  {
  case 1:
    *(uint8_t *)addr = data;
    break;
  case 2:
    *(uint16_t *)addr = data;
    break;
  case 4:
    *(uint32_t *)addr = data;
    break;
  case 8:
    *(uint64_t *)addr = data;
    break;
  default:
    assert(0);
  }
}

static void log_watched_write(word_t addr, word_t data, char wmask,
                              uint8_t *host_addr, size_t len)
{
  static bool initialized = false;
  static bool enabled = false;
  static word_t watched_addr = 0;
  if (!initialized)
  {
    const char *value = getenv("NSIM_MEM_WATCH_ADDR");
    if (value != NULL && *value != '\0')
    {
      watched_addr = (word_t)strtoull(value, NULL, 0);
      enabled = true;
      Log("memory write watch: address=" FMT_WORD, watched_addr);
    }
    initialized = true;
  }
  if (!enabled || watched_addr < addr || watched_addr >= addr + len)
    return;

  word_t old_data = host_read(host_addr, (int)len);
  Log("memory write watch: time=%llu rpc=" FMT_WORD " npc=" FMT_WORD
      " addr=" FMT_WORD " old=" FMT_WORD " data=" FMT_WORD " mask=0x%02x",
      (unsigned long long)contextp->time(), *npc.rpc, *npc.pc, addr,
      old_data, data, wmask & 0xff);
}

extern "C" void sdram_read(word_t addr, uint8_t *data)
{
  size_t offset;
  if (!map_range_offset(addr, SDRAM_BASE, SDRAM_SIZE, 1, &offset))
  {
    report_invalid_host_access("sdram", "read", (uint32_t)addr, 1);
    *data = 0;
    return;
  }
  *data = memory.sdram[offset];
  // Log(" sdram raddr: 0x%x, rdata: 0x%02x, offest: 0x%02x", (uint32_t)addr, *data, offset);
}

extern "C" void sdram_write(word_t addr, uint8_t data, uint8_t wmask)
{
  size_t offset;
  if (!map_range_offset(addr, SDRAM_BASE, SDRAM_SIZE, 1, &offset))
  {
    report_invalid_host_access("sdram", "write", (uint32_t)addr, 1);
    return;
  }
  memory.sdram[offset] = data;
  // Log("sdram waddr: 0x%x, wdata: 0x%02x, offest: 0x%02x", (uint32_t)addr, data, offset);
}

extern "C" void pmem_read(word_t raddr, word_t *rdata)
{
#ifdef CONFIG_ISA64
  // Canonicalise RV64 sign-extended physical addresses (0xffffffff8xxxxxxx)
  raddr = (word_t)((uint32_t)raddr);
#endif
  word_t addr = raddr;
  word_t data = 0;
  // Log("raddr: " FMT_WORD_NO_PREFIX, addr);
#ifdef CONFIG_SOFT_MMIO
  if (raddr == RTC_ADDR_ + 4)
  {
    uint64_t t = get_time();
    memory.rtc_port_base[0] = (uint32_t)(t >> 32);
    data = memory.rtc_port_base[0];
    *rdata = data;
    difftest_skip_ref();
    return;
  }
  else if (raddr == RTC_ADDR_)
  {
    uint64_t t = get_time();
    memory.rtc_port_base[1] = (uint32_t)(t);
    data = memory.rtc_port_base[1];
    *rdata = data;
    difftest_skip_ref();
    return;
  }
#endif
  if (mmio_check_and_handle(addr, 0, 0, false, &data))
  {
    // Log("  MMIO read: addr = " FMT_WORD ", data = " FMT_WORD,
    //     addr, data);
    *rdata = data;
    return;
  }
  uint8_t *host_addr = guest_to_host(addr);
  if (host_addr == NULL)
  {
    // Unmapped physical read: return 0 silently so RTL can continue
    // (matches RISCOF sail reference behavior and allows PMP/illegal-inst
    //  trap semantics to be tested without aborting the simulation).
    *rdata = 0;
    return;
  }
  host_addr = (uint8_t *)((uintptr_t)host_addr & ~(uintptr_t)(sizeof(word_t) - 1));
  data = host_read(host_addr, sizeof(word_t));
  *rdata = data;
  // Log("raddr: " FMT_WORD_NO_PREFIX ", data: " FMT_WORD_NO_PREFIX,
  //     addr, data);
}

extern "C" void pmem_write(word_t waddr, word_t wdata, char wmask)
{
#ifdef CONFIG_ISA64
  waddr = (word_t)((uint32_t)waddr);
#endif
  word_t addr = waddr;
  word_t data = wdata;
  // Log("waddr: " FMT_WORD ", wdata: " FMT_WORD ", wmask = 0x%02x",
  //     addr, data, wmask & 0xff);
#ifdef CONFIG_SOFT_MMIO
  // SERIAL_MMIO: hex "MMIO address of the serial controller"
  if (addr == SERIAL_PORT)
  {
    putchar(data);
    difftest_skip_ref();
    return;
  }
#endif
  if (mmio_check_and_handle(addr, data, wmask, true, NULL))
  {
    // Log("MMIO write: addr = " FMT_WORD ", data = " FMT_WORD ", mask = %02x",
    //     addr, data, wmask & 0xff);
    return;
  }
  uint8_t *host_addr = guest_to_host(addr);
  if (host_addr == NULL)
  {
    // Unmapped physical write: drop silently so RTL can continue
    // (matches RISCOF sail reference behavior).
    return;
  }
  switch (wmask)
  {
  case 0x1:
    log_watched_write(addr, data, wmask, host_addr, 1);
    host_write(host_addr, data, 1);
    break;
  case 0x3:
    log_watched_write(addr, data, wmask, host_addr, 2);
    host_write(host_addr, data, 2);
    break;
  case 0x7:
    log_watched_write(addr, data, wmask, host_addr, 3);
    host_write(host_addr, data, 3);
    break;
  case 0xf:
    log_watched_write(addr, data, wmask, host_addr, 4);
    host_write(host_addr, data, 4);
    break;
  case 0x7f:
    log_watched_write(addr, data, wmask, host_addr, 7);
    host_write(host_addr, data, 7);
    break;
  case (char)0xff:
    log_watched_write(addr, data, wmask, host_addr, 8);
    host_write(host_addr, data, 8);
    break;
  default:
    Log(FMT_RED("Invalid write: addr = " FMT_WORD ", data = " FMT_WORD ", mask = %02x"),
        addr, data, wmask & 0xff);
    break;
  }
}

extern "C" void flash_read(uint32_t addr, uint32_t *data)
{
  uint32_t flash_addr = addr;
  if (flash_addr >= FLASH_BASE)
    flash_addr -= FLASH_BASE;
  if ((uint64_t)flash_addr + sizeof(uint32_t) > FLASH_SIZE)
  {
    report_invalid_host_access("flash", "read", addr, sizeof(uint32_t));
    *data = 0;
    return;
  }
  *data = host_read(memory.flash + flash_addr, sizeof(uint32_t));
  // Log("flash raddr: 0x%08x, rdata: 0x%08x, offest: 0x%08x", addr, *data, offset);
}

extern "C" void mrom_read(uint32_t addr, uint32_t *data)
{
  paddr_t aligned_addr = (paddr_t)(addr & 0xfffffffcu);
  size_t offset;
  if (!map_range_offset(aligned_addr, MROM_BASE, MROM_SIZE, sizeof(uint32_t), &offset))
  {
    report_invalid_host_access("mrom", "read", addr, sizeof(uint32_t));
    *data = 0;
    return;
  }
  *data = host_read(memory.mrom + offset, sizeof(uint32_t));
  // Log("mrom raddr: 0x%x, rdata: 0x%x, offest: 0x%x", addr, *data, offset);
}

void vaddr_show(vaddr_t addr, int n)
{
  word_t data;
  word_t wsize = 4;
  for (word_t i = 0; i < (n / 4 + 1); i++)
  {
    if (i % 4 == 0)
    {
      if (i != 0)
      {
        printf("| ");
        for (size_t j = 0; j < wsize; j++)
        {
          data = host_read(guest_to_host(addr + (i - (3 - j) - 1) * wsize), 4);
          for (size_t k = 0; k < wsize; k++)
          {
            uint8_t c = (data >> (((wsize)-1 - k) * 8)) & 0xff;
            printf("%02x ", c);
          }
          printf(" ");
        }
        printf("\n");
      }
      printf("" FMT_WORD ": ", addr + i * wsize);
    }
    data = host_read(guest_to_host(addr + i * wsize), 4);
    printf("" FMT_WORD " ", data);
  }
  printf("\n");
}

void init_mem()
{
  void init_serial();
  init_serial();
  void init_virtio_blk();
  init_virtio_blk();
  void init_sdhci();
  init_sdhci();
  void init_litex_spi();
  init_litex_spi();
  void init_litex_uart();
  init_litex_uart();
}
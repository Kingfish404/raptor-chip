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

#include <isa.h>
#ifdef CONFIG_ISA_riscv
#include <isa-extensions.h>
#endif
#include <cpu/thread.h>
#include <cpu/multidiff.h>
#include <cpu/diffjournal.h>
#include <memory/paddr.h>
#include <device/mmio.h>
#include <device/block-image.h>
#include <inttypes.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>

extern char *btb_file;
extern long long int max_inst;

void init_rand();
void init_log(const char *log_file);
void init_mem();
void init_difftest(char *ref_so_file, long img_size, int port);
void init_device();
void init_sdb();
void init_disasm();
void print_nemu_machine(void);
#ifdef CONFIG_HAS_SERIAL
void serial_set_lf_to_cr(bool enable);
void serial_set_stdout(bool enable);
#endif

static void welcome()
{
  Log("Trace: %s", MUXDEF(CONFIG_TRACE, ANSI_FMT("ON", ANSI_FG_GREEN), ANSI_FMT("OFF", ANSI_FG_RED)));
  IFDEF(CONFIG_TRACE, Log("If trace is enabled, a log file will be generated "
                          "to record the trace. This may lead to a large log file. "
                          "If it is not necessary, you can disable it in menuconfig"));
  Log("Build time: %s, %s", __TIME__, __DATE__);
  printf("Welcome to %s-NEMU!\n", ANSI_FMT(str(__GUEST_ISA__), ANSI_FG_YELLOW ANSI_BG_RED));
  printf("For help, type \"help or h\"\n");
  fflush(stdout);
}

#ifndef CONFIG_TARGET_AM
#include <getopt.h>

void sdb_set_batch_mode();
static bool batch_requested;
static bool hostfwd_requested;
#ifdef CONFIG_HAS_NET
int net_add_hostfwd(const char *spec);
#endif

int boot_from_flash = 0;

static char *log_file = NULL;
static char *diff_so_file = NULL;
static char *img_file = NULL;
static char *disk_img_file = NULL;
static NemuBlockMode disk_mode;
static bool disk_mode_requested;
static char *sdcard_img_file = NULL;
static int difftest_port = 1234;
#ifdef NEMU_HAS_SMP
static bool net_backend_requested;
#endif
#ifdef CONFIG_HAS_DISK
void virtio_blk_set_disk_image(const char *path);
void virtio_blk_set_disk_mode(NemuBlockMode mode);
#endif
#ifdef CONFIG_HAS_SDCARD
void sdcard_set_image(const char *path);
#endif

static long load_img()
{
  if (img_file == NULL)
  {
    Log("No image is given. Use the default build-in image.");
    return 4096; // built-in image size
  }

  FILE *fp = fopen(img_file, "rb");
  Assert(fp, "Can not open '%s'", img_file);

  fseek(fp, 0, SEEK_END);
  long size = ftell(fp);

  Log("The image is %s, size = %ld", img_file, size);

  fseek(fp, 0, SEEK_SET);
  int ret = fread(guest_to_host(RESET_VECTOR), size, 1, fp);
  assert(ret == 1);
  if (boot_from_flash)
  {
    Log("Boot from flash");
    memcpy(guest_to_host(CONFIG_FLASH_BASE), guest_to_host(RESET_VECTOR), size);
  }

  fclose(fp);
  return size;
}

typedef struct
{
  const char *name;
  uint64_t base;
  uint64_t size;
  const char *desc;
} map_print_entry_t;

static void print_map_entry(FILE *out, const char *kind, const char *name,
                            uint64_t base, uint64_t size, const char *desc)
{
  uint64_t high = (size == 0) ? base : base + size - 1;
  fprintf(out, "  %-6s %-18s 0x%08" PRIx64 "  0x%08" PRIx64 "  0x%08" PRIx64,
          kind, name, base, high, size);
  if (desc != NULL && desc[0] != '\0')
  {
    fprintf(out, "  %s", desc);
  }
  fprintf(out, "\n");
}

static int compare_map_print_entry(const void *lhs_ptr, const void *rhs_ptr)
{
  const map_print_entry_t *lhs = (const map_print_entry_t *)lhs_ptr;
  const map_print_entry_t *rhs = (const map_print_entry_t *)rhs_ptr;
  if (lhs->base < rhs->base)
  {
    return -1;
  }
  if (lhs->base > rhs->base)
  {
    return 1;
  }
  if (lhs->size < rhs->size)
  {
    return -1;
  }
  if (lhs->size > rhs->size)
  {
    return 1;
  }
  return strcmp(lhs->name, rhs->name);
}

static void print_map_entries_sorted(FILE *out, const char *kind,
                                     map_print_entry_t *entries, size_t count)
{
  qsort(entries, count, sizeof(entries[0]), compare_map_print_entry);
  for (size_t i = 0; i < count; i++)
  {
    print_map_entry(out, kind, entries[i].name, entries[i].base,
                    entries[i].size, entries[i].desc);
  }
}

#ifdef CONFIG_DEVICE
static void print_configured_mmio_maps(FILE *out)
{
  map_print_entry_t entries[32];
  size_t count = 0;
#ifdef CONFIG_HAS_SERIAL
#ifndef CONFIG_HAS_PORT_IO
  entries[count++] = (map_print_entry_t){"serial", CONFIG_SERIAL_MMIO, 8, "legacy serial port"};
  entries[count++] = (map_print_entry_t){"serial_ns16550", CONFIG_SERIAL_MMIO_US16550, 0x100, "QEMU virt NS16550 UART"};
#endif
#endif
#ifdef CONFIG_HAS_TIMER
#ifndef CONFIG_HAS_PORT_IO
  entries[count++] = (map_print_entry_t){"rtc", CONFIG_RTC_MMIO, 8, "legacy RTC port"};
  entries[count++] = (map_print_entry_t){"clint", CONFIG_RTC_MMIO_CLINT, 0x000c0000, "QEMU virt CLINT"};
#endif
#endif
#ifdef CONFIG_HAS_FINISHER
  entries[count++] = (map_print_entry_t){"finisher", CONFIG_FINISHER_MMIO, 0x1000, "SiFive test / syscon poweroff"};
#endif
#ifdef CONFIG_HAS_VGA
#ifndef CONFIG_HAS_PORT_IO
  entries[count++] = (map_print_entry_t){"vgactl", CONFIG_VGA_CTL_MMIO, 8, "VGA control registers"};
#endif
  entries[count++] = (map_print_entry_t){"vmem", CONFIG_FB_ADDR__, MUXDEF(CONFIG_VGA_SIZE_800x600, 800 * 600 * 4, 400 * 300 * 4), "VGA frame buffer"};
#endif
#ifdef CONFIG_HAS_KEYBOARD
#ifndef CONFIG_HAS_PORT_IO
  entries[count++] = (map_print_entry_t){"keyboard", CONFIG_I8042_DATA_MMIO, 4, "i8042 keyboard data port"};
#endif
#endif
#ifdef CONFIG_HAS_AUDIO
#ifndef CONFIG_HAS_PORT_IO
  entries[count++] = (map_print_entry_t){"audio", CONFIG_AUDIO_CTL_MMIO, 0x18, "audio control registers"};
#endif
  entries[count++] = (map_print_entry_t){"audio-sbuf", CONFIG_SB_ADDR, CONFIG_SB_SIZE, "audio stream buffer"};
#endif
#ifdef CONFIG_HAS_DISK
  entries[count++] = (map_print_entry_t){"virtio-blk", 0x10001000, 0x1000, "QEMU virtio-mmio block device"};
#endif
#ifdef CONFIG_HAS_NET
  entries[count++] = (map_print_entry_t){"virtio-net", CONFIG_NET_MMIO, 0x1000, "virtio-mmio network with user-mode NAT"};
#endif
#ifdef CONFIG_HAS_RNG
  entries[count++] = (map_print_entry_t){"virtio-rng", CONFIG_RNG_MMIO, 0x1000, "virtio-mmio host entropy source"};
#endif
#ifdef CONFIG_HAS_SDCARD
  entries[count++] = (map_print_entry_t){"sdhci-pci-ecam", 0x30008000, 0x1000, "QEMU SDHCI PCI ECAM stub"};
  entries[count++] = (map_print_entry_t){"sdhci", CONFIG_SDCARD_CTL_MMIO, 0x100, "QEMU SDHCI SD-card controller"};
#endif
#ifndef CONFIG_TARGET_AM
  entries[count++] = (map_print_entry_t){"plic", CONFIG_PLIC_MMIO, 0x01000000, "QEMU virt PLIC"};
#endif
  print_map_entries_sorted(out, "mmio", entries, count);
}
#endif

void print_nemu_memory_map(FILE *out)
{
  if (out == NULL)
  {
    out = stdout;
  }

  fprintf(out, "Memory map (current NEMU build; MMIO has priority over host-backed overlays):\n");
  fprintf(out, "  %-6s %-18s %-10s  %-10s  %-10s  %s\n",
          "kind", "name", "base", "end", "size", "description");
  map_print_entry_t mem_entries[] = {
      {"rom", CONFIG_ROM_BASE, CONFIG_ROM_SIZE, "QEMU virt reset ROM / DTB"},
      {"sram", CONFIG_SRAM_BASE, CONFIG_SRAM_SIZE, "on-chip SRAM window"},
      {"mrom", CONFIG_MROM_BASE, CONFIG_MROM_SIZE, "mask ROM window"},
      {"flash", CONFIG_FLASH_BASE, CONFIG_FLASH_SIZE, "flash image mirror"},
      {"pmem", CONFIG_MBASE, CONFIG_MSIZE, "main memory / QEMU virt DRAM"},
#ifndef CONFIG_RAPTOR_PMEM_2G
      {"sdram", CONFIG_SDRAM_BASE, CONFIG_SDRAM_SIZE, "external SDRAM window"},
#endif
  };
  print_map_entries_sorted(out, "mem", mem_entries, sizeof(mem_entries) / sizeof(mem_entries[0]));
#ifdef CONFIG_DEVICE
  if (mmio_map_count() > 0)
  {
    print_mmio_maps(out);
  }
  else
  {
    print_configured_mmio_maps(out);
  }
#endif
  fprintf(out, "\n");
}

void usage(int argc, char *argv[])
{
  printf("Usage: %s [OPTION...] IMAGE [args]\n\n", argv[0]);
  printf("Options:\n");
  printf("      --isa-extensions=SET  none (default) or rva23 (RV64 cycle-based profile)\n");
  printf("  -b, --batch              run with batch mode\n");
  printf("  -f, --flash              boot from flash\n");
  printf("  -l, --log=FILE           output log to FILE\n");
  printf("  -d, --diff=REF_SO        run DiffTest with reference REF_SO\n");
  printf("      --diff-mode=MODE     legacy (default) or multihart (strict rr baseline)\n");
  printf("      --diff-record=FILE   record memory-only rr/threaded replay journal\n");
  printf("      --diff-stream-fd=N   stream the journal to an inherited write-only pipe (N >= 3)\n");
  printf("      --diff-interrupts    enable checked CPU interrupt entry and WFI (journal v2)\n");
  printf("      --diff-clint         enable checked CLINT/time inputs and IRQs (journal v3)\n");
  printf("      --diff-plic          also check PLIC MMIO and source inputs (journal v4)\n");
  printf("      --diff-plic-input=FILE  ordered raw tick/source pulse pairs (requires --diff-plic)\n");
  printf("      --diff-uart          also check ns16550 UART and derived IRQs (journal v5)\n");
  printf("      --diff-rng           also check virtio-rng/DMA (v7; requires retained TLB and pthreads)\n");
  printf("      --diff-rng-input=FILE  read deterministic entropy instead of /dev/urandom\n");
  printf("      --diff-net           also check virtio-net TX/RX/DMA (journal v8)\n");
  printf("      --diff-block         also check virtio-blk with independent disk image (journal v9)\n");
  printf("      --diff-net-backend=MODE  slirp (default) or script (no host networking)\n");
  printf("      --diff-net-input=FILE  ordered tx|poll AFTER_TX HEX lines for script backend\n");
  printf("      --diff-uart-input=FILE  ordered raw tick/byte pairs (requires --diff-uart)\n");
  printf("      --diff-uart-stdin    record stdin RX during serialized timer polls\n");
  printf("      --diff-progress=N   report journal progress every N retirements (0 disables)\n");
  printf("      --diff-tlb=MODE     flush (default) or retain (requires UART journal and threaded backend)\n");
  printf("      --diff-record-max-bytes=N  total limit (file default 268435456; stream unlimited; 64..1099511627776)\n");
  printf("  -p, --port=PORT          run DiffTest with port PORT\n");
  printf("  -e, --elf=ELF_FILE       add ELF_FILE for ftrace\n");
  printf("  -t, --tree=BTB_FILE      add BTB_FILE for rom\n");
  printf("      --disk=DISK_IMAGE    attach a raw virtio-mmio block image\n");
  printf("      --disk-mode=MODE     volatile (default), readonly or persistent (writes host file)\n");
  printf("      --hostfwd=SPEC       tcp:HOST_PORT:GUEST_PORT; loopback -> 10.0.2.15 (up to 16)\n");
  printf("      --smp=N              number of harts (1..%u; requires matching DTB)\n", NEMU_MAX_HARTS);
  printf("      --smp-backend=MODE   rr (default) or threaded; no rebuild required\n");
  printf("      --smp-clock-div=N    threaded guest clock divisor (1..1000; default 16)\n");
  printf("      --sdcard=SD_IMAGE    attach a QEMU SDHCI SD-card image\n");
#ifdef CONFIG_HAS_SERIAL
  printf("      --serial-lf-to-cr    translate host LF input to CR for CR-terminated monitors\n");
  printf("      --serial-stdout     send guest UART output to stdout instead of stderr\n");
#endif
  printf("  -m, --maximum=NUM        set the maximum number of instructions to execute\n");
  printf("  -n, --none               do nothing\n");
  printf("      --sig=SPEC           dump RISCOF signature (SPEC=<hex_begin>-<hex_end>:<path>)\n");
  printf("  -h, --help               display this help and exit\n");
  printf("      --describe          print compiled machine capabilities as JSON and exit\n");
  printf("\n");
  print_nemu_memory_map(stdout);
}

static int parse_args(int argc, char *argv[])
{
  const struct option table[] = {
      {"batch", no_argument, NULL, 'b'},
      {"flash", no_argument, NULL, 'f'},
      {"log", required_argument, NULL, 'l'},
      {"diff", required_argument, NULL, 'd'},
      {"port", required_argument, NULL, 'p'},
      {"elf", required_argument, NULL, 'e'},
      {"tree", required_argument, NULL, 't'},
      {"maximum", required_argument, NULL, 'm'},
      {"none", no_argument, NULL, 'n'},
      {"disk", required_argument, NULL, 257},
      {"disk-mode", required_argument, NULL, 284},
      {"describe", no_argument, NULL, 285},
      {"hostfwd", required_argument, NULL, 286},
      {"sdcard", required_argument, NULL, 258},
      {"smp", required_argument, NULL, 260},
      {"smp-backend", required_argument, NULL, 261},
      {"smp-clock-div", required_argument, NULL, 262},
      {"diff-mode", required_argument, NULL, 263},
      {"diff-record", required_argument, NULL, 264},
      {"diff-record-max-bytes", required_argument, NULL, 265},
      {"diff-stream-fd", required_argument, NULL, 266},
      {"diff-interrupts", no_argument, NULL, 267},
      {"diff-clint", no_argument, NULL, 268},
      {"diff-plic", no_argument, NULL, 269},
      {"diff-plic-input", required_argument, NULL, 270},
      {"diff-uart", no_argument, NULL, 271},
      {"diff-uart-input", required_argument, NULL, 272},
      {"diff-uart-stdin", no_argument, NULL, 273},
      {"diff-progress", required_argument, NULL, 274},
      {"diff-tlb", required_argument, NULL, 275},
      {"diff-rng", no_argument, NULL, 276},
      {"diff-rng-input", required_argument, NULL, 277},
      {"diff-net", no_argument, NULL, 278},
      {"diff-net-backend", required_argument, NULL, 279},
      {"diff-net-input", required_argument, NULL, 280},
      {"diff-block", no_argument, NULL, 281},
      {"isa-extensions", required_argument, NULL, 283},
#ifdef CONFIG_HAS_SERIAL
      {"serial-lf-to-cr", no_argument, NULL, 259},
      {"serial-stdout", no_argument, NULL, 282},
#endif
      {"help", no_argument, NULL, 'h'},
      {"sig", required_argument, NULL, 256},
      {0, 0, NULL, 0},
  };
  int o;
  if (argc == 1)
  {
    usage(argc, argv);
    exit(0);
  }
  while ((o = getopt_long(argc, argv, "-bfl:d:p:e:t:m:hn", table, NULL)) != -1)
  {
    switch (o)
    {
    case 286:
#ifdef CONFIG_HAS_NET
      if (net_add_hostfwd(optarg) == 0) {
        hostfwd_requested = true;
        break;
      }
      fprintf(stderr, "--hostfwd requires tcp:HOST_PORT:GUEST_PORT, ports 1..65535, at most 16 unique host ports (UDP unsupported)\n");
#else
      fprintf(stderr, "--hostfwd requires a build with CONFIG_HAS_NET\n");
#endif
      exit(EXIT_FAILURE);
    case 285:
      print_nemu_machine();
      exit(0);
    case 283:
#ifdef CONFIG_ISA_riscv
      if (riscv_isa_configure_names(optarg) == 0) break;
#endif
      fprintf(stderr, "--isa-extensions requires none or rva23 (RV64 system mode with F, D, Svade and CONFIG_TIMER_CYCLE required)\n");
      exit(EXIT_FAILURE);
    case 'b':
      batch_requested = true;
      sdb_set_batch_mode();
      break;
    case 'f':
      boot_from_flash = 1;
      break;
    case 'p':
      sscanf(optarg, "%d", &difftest_port);
      break;
    case 275:
#ifdef NEMU_HAS_SMP
      if (!strcmp(optarg, "flush")) nemu_md_tlb_retain = false;
      else if (!strcmp(optarg, "retain")) nemu_md_tlb_retain = true;
      else {
        fprintf(stderr, "--diff-tlb requires flush or retain\n");
        exit(1);
      }
      break;
#else
      fprintf(stderr, "--diff-tlb requires native RISC-V journal support\n");
      exit(1);
#endif
    case 274:
    {
      char *end = NULL;
      unsigned long long interval = strtoull(optarg, &end, 10);
      if (!*optarg || strspn(optarg, "0123456789") != strlen(optarg) || *end || interval > (1ull << 40)) {
        fprintf(stderr, "--diff-progress requires 0..1099511627776\n");
        exit(1);
      }
#ifdef NEMU_HAS_SMP
      nemu_journal_progress_interval = interval;
#else
      fprintf(stderr, "--diff-progress requires native RISC-V journal support\n");
      exit(1);
#endif
      break;
    }
    case 273:
#ifdef NEMU_HAS_SMP
      nemu_uart_stdin = true;
      break;
#else
      fprintf(stderr, "--diff-uart-stdin requires native RISC-V journal support\n");
      exit(1);
#endif
    case 272:
#ifdef NEMU_HAS_SMP
      nemu_uart_input_path = optarg;
      break;
#else
      fprintf(stderr, "--diff-uart-input requires native RISC-V journal support\n");
      exit(1);
#endif
    case 277:
#ifdef NEMU_HAS_SMP
      nemu_rng_input_path = optarg;
      break;
#else
      fprintf(stderr, "--diff-rng-input requires native RISC-V journal support\n");
      exit(1);
#endif
    case 280:
#ifdef NEMU_HAS_SMP
      nemu_net_input_path = optarg;
      break;
#else
      fprintf(stderr, "--diff-net-input requires native RISC-V journal support\n");
      exit(1);
#endif
    case 279:
#ifdef NEMU_HAS_SMP
      if (strcmp(optarg, "script") && strcmp(optarg, "slirp")) {
        fprintf(stderr, "--diff-net-backend requires slirp or script\n");
        exit(1);
      }
      nemu_net_script = !strcmp(optarg, "script");
      net_backend_requested = true;
      break;
#else
      fprintf(stderr, "--diff-net-backend requires native RISC-V journal support\n");
      exit(1);
#endif
    case 281:
#if defined(NEMU_HAS_SMP) && defined(CONFIG_HAS_DISK)
      nemu_md_block = true;
      __attribute__((fallthrough));
#else
      fprintf(stderr, "--diff-block requires native virtio-blk support\n");
      exit(1);
#endif
    case 278:
#if defined(NEMU_HAS_SMP) && defined(CONFIG_HAS_NET) && CONFIG_NET_MMIO == 0x10002000 && CONFIG_NET_PLIC_IRQ == 2
      nemu_md_net = true;
      __attribute__((fallthrough));
#else
      fprintf(stderr, "--diff-net requires native virtio-net at 0x10002000 with IRQ2\n");
      exit(1);
#endif
    case 276:
#if defined(NEMU_HAS_SMP) && defined(CONFIG_HAS_RNG) && CONFIG_RNG_MMIO == 0x10003000 && CONFIG_RNG_PLIC_IRQ == 3
      nemu_md_rng = true;
      __attribute__((fallthrough));
#else
      fprintf(stderr, "--diff-rng requires native virtio-rng at 0x10003000 with IRQ3\n");
      exit(1);
#endif
    case 271:
#if defined(NEMU_HAS_SMP) && defined(CONFIG_DEVICE) && defined(CONFIG_HAS_TIMER) && defined(CONFIG_HAS_SERIAL) && defined(CONFIG_SERIAL_INPUT_FIFO) && !defined(CONFIG_HAS_PORT_IO) && CONFIG_RTC_MMIO_CLINT == 0x02000000 && CONFIG_PLIC_MMIO == 0x0c000000 && CONFIG_SERIAL_MMIO_US16550 == 0x10000000 && CONFIG_SERIAL_PLIC_IRQ == 10
      nemu_md_uart = true;
      nemu_md_plic = true;
      nemu_md_clint = true;
      nemu_md_interrupts = true;
      break;
#else
      fprintf(stderr, "--diff-uart requires native ns16550/CLINT/PLIC with RX FIFO and UART IRQ10\n");
      exit(1);
#endif
    case 270:
#ifdef NEMU_HAS_SMP
      nemu_plic_input_path = optarg;
      break;
#else
      fprintf(stderr, "--diff-plic-input requires native RISC-V journal support\n");
      exit(1);
#endif
    case 269:
#if defined(NEMU_HAS_SMP) && defined(CONFIG_DEVICE) && defined(CONFIG_HAS_TIMER) && CONFIG_RTC_MMIO_CLINT == 0x02000000 && CONFIG_PLIC_MMIO == 0x0c000000
      nemu_md_plic = true;
      nemu_md_clint = true;
      nemu_md_interrupts = true;
      break;
#else
      fprintf(stderr, "--diff-plic requires native CLINT/PLIC at 0x02000000/0x0c000000\n");
      exit(1);
#endif
    case 268:
#if defined(NEMU_HAS_SMP) && defined(CONFIG_DEVICE) && defined(CONFIG_HAS_TIMER) && CONFIG_RTC_MMIO_CLINT == 0x02000000
      nemu_md_clint = true;
      nemu_md_interrupts = true;
      break;
#else
      fprintf(stderr, "--diff-clint requires the native RISC-V CLINT at 0x02000000\n");
      exit(1);
#endif
    case 267:
#ifdef NEMU_HAS_SMP
      nemu_md_interrupts = true;
      break;
#else
      fprintf(stderr, "--diff-interrupts requires a native RISC-V system build with SMP\n");
      exit(1);
#endif
    case 266:
    {
      char *end = NULL;
      unsigned long descriptor = strtoul(optarg, &end, 10);
      if (!*optarg || strspn(optarg, "0123456789") != strlen(optarg) || *end ||
          descriptor < 3 || descriptor > 0x7ffffffful) {
        fprintf(stderr, "--diff-stream-fd requires a descriptor in 3..2147483647\n");
        exit(1);
      }
#ifdef NEMU_HAS_SMP
      nemu_journal_fd = descriptor;
#else
      fprintf(stderr, "--diff-stream-fd requires a native RISC-V system build with SMP\n");
      exit(1);
#endif
      break;
    }
    case 265:
    {
      char *end = NULL;
      unsigned long long limit = strtoull(optarg, &end, 10);
      if (!*optarg || strspn(optarg, "0123456789") != strlen(optarg) || *end ||
          limit < 64 || limit > (1ull << 40)) {
        fprintf(stderr, "--diff-record-max-bytes requires 64..1099511627776\n");
        exit(1);
      }
#ifdef NEMU_HAS_SMP
      nemu_journal_max_bytes = limit;
      nemu_journal_limit_explicit = true;
#else
      fprintf(stderr, "--diff-record-max-bytes requires a native RISC-V system build with SMP\n");
      exit(1);
#endif
      break;
    }
    case 264:
#ifdef NEMU_HAS_SMP
      nemu_journal_path = optarg;
      break;
#else
      fprintf(stderr, "--diff-record requires a native RISC-V system build with SMP\n");
      exit(1);
#endif
    case 263:
#ifdef NEMU_HAS_SMP
      if (strcmp(optarg, "multihart") == 0) nemu_multidiff_requested = true;
      else if (strcmp(optarg, "legacy") == 0) nemu_multidiff_requested = false;
      else {
        fprintf(stderr, "--diff-mode requires legacy or multihart\n");
        exit(1);
      }
      break;
#else
      fprintf(stderr, "--diff-mode requires a native RISC-V system build with SMP\n");
      exit(1);
#endif
    case 'l':
      log_file = optarg;
      break;
    case 'd':
      diff_so_file = optarg;
      break;
    case 'e':
      isa_parser_elf(optarg);
      break;
    case 't':
      btb_file = optarg;
      break;
    case 257:
      disk_img_file = optarg;
      break;
    case 284:
      if (!strcmp(optarg, "volatile")) disk_mode = NEMU_BLOCK_VOLATILE;
      else if (!strcmp(optarg, "readonly")) disk_mode = NEMU_BLOCK_READONLY;
      else if (!strcmp(optarg, "persistent")) disk_mode = NEMU_BLOCK_PERSISTENT;
      else {
        fprintf(stderr, "--disk-mode requires volatile, readonly or persistent\n");
        exit(1);
      }
      disk_mode_requested = true;
      break;
    case 258:
      sdcard_img_file = optarg;
      break;
    case 262:
    {
      char *end = NULL;
      unsigned long divisor = strtoul(optarg, &end, 10);
      if (!*optarg || *end || divisor < 1 || divisor > 1000)
      {
        fprintf(stderr, "--smp-clock-div requires 1..1000\n");
        exit(1);
      }
#ifdef NEMU_HAS_THREADS
      nemu_thread_clock_div = divisor;
#else
      fprintf(stderr, "--smp-clock-div requires standalone RISC-V with timer devices\n");
      exit(1);
#endif
      break;
    }
    case 261:
      if (strcmp(optarg, "rr") == 0)
      {
        IFDEF(NEMU_HAS_THREADS, nemu_threaded = false);
      }
#ifdef NEMU_HAS_THREADS
      else if (strcmp(optarg, "threaded") == 0)
        nemu_threaded = true;
#endif
      else
      {
        fprintf(stderr, "--smp-backend requires rr or threaded (standalone RISC-V with timer devices)\n");
        exit(1);
      }
      break;
    case 260:
    {
      char *end = NULL;
      unsigned long count = strtoul(optarg, &end, 10);
      if (!*optarg || *end || count < 1 || count > NEMU_MAX_HARTS)
      {
        fprintf(stderr, "--smp requires 1..%u harts\n", NEMU_MAX_HARTS);
        exit(1);
      }
      IFDEF(NEMU_HAS_SMP, nemu_nr_harts = count);
      break;
    }
#ifdef CONFIG_HAS_SERIAL
    case 259:
      serial_set_lf_to_cr(true);
      break;
    case 282:
      serial_set_stdout(true);
      break;
#endif
    case 'm':
      sscanf(optarg, "%lld", &max_inst);
      break;
    case 'n':
      break;
    case 256:
    {
      int sig_set_range(const char *spec);
      if (sig_set_range(optarg) != 0)
      {
        printf("ERROR: invalid --sig spec: %s (expected <hex_begin>-<hex_end>:<path>)\n", optarg);
        exit(1);
      }
      break;
    }
    case 1:
      img_file = optarg;
      return 0;
    case 0:
    default:
      usage(argc, argv);
      exit(0);
    }
  }
  return 0;
}

void init_monitor(int argc, char *argv[])
{
  /* Perform some global initialization. */

  /* Parse arguments. */
  parse_args(argc, argv);
  if (hostfwd_requested && (diff_so_file ||
      IFDEF(NEMU_HAS_SMP, nemu_net_script || nemu_multidiff_requested ||
            (nemu_journal_requested() && !nemu_md_net) ||) false)) {
    fprintf(stderr, "--hostfwd requires standalone slirp networking or a --diff-net journal, not script/lockstep/legacy DiffTest\n");
    exit(1);
  }
  if (disk_img_file && !*disk_img_file) {
    fprintf(stderr, "--disk requires a nonempty image path\n");
    exit(1);
  }
  if (disk_mode_requested && (!disk_img_file || !*disk_img_file)) {
    fprintf(stderr, "--disk-mode requires --disk=IMAGE\n");
    exit(1);
  }
#ifndef CONFIG_HAS_DISK
  if (disk_img_file || disk_mode_requested) {
    fprintf(stderr, "--disk requires a build with CONFIG_HAS_DISK\n");
    exit(1);
  }
#endif
  if (disk_mode != NEMU_BLOCK_VOLATILE && (diff_so_file ||
      IFDEF(NEMU_HAS_SMP, nemu_multidiff_requested || nemu_journal_requested() ||) false)) {
    fprintf(stderr, "DiffTest and journal replay require --disk-mode=volatile\n");
    exit(1);
  }
#ifdef NEMU_HAS_SMP
  if ((net_backend_requested && !nemu_md_net) ||
      (nemu_net_input_path && (!nemu_md_net || !nemu_net_script))) {
    fprintf(stderr, "--diff-net-backend requires --diff-net; --diff-net-input also requires script backend\n");
    exit(1);
  }
  if (nemu_rng_input_path && !nemu_md_rng) {
    fprintf(stderr, "--diff-rng-input requires --diff-rng\n");
    exit(1);
  }
  if (nemu_md_rng && (!nemu_md_tlb_retain || !nemu_threaded || !nemu_journal_requested())) {
    fprintf(stderr, "%s requires --diff-tlb=retain, --smp-backend=threaded and a journal transport\n",
            nemu_md_block ? "--diff-block" : nemu_md_net ? "--diff-net" : "--diff-rng");
    exit(1);
  }
  if (nemu_md_tlb_retain && (!nemu_journal_requested() || !nemu_md_uart || !nemu_threaded)) {
    fprintf(stderr, "--diff-tlb=retain requires --diff-uart, --smp-backend=threaded and a journal transport\n");
    exit(1);
  }
  if (nemu_journal_progress_interval && !nemu_journal_requested()) {
    fprintf(stderr, "--diff-progress requires --diff-record or --diff-stream-fd\n");
    exit(1);
  }
  if (nemu_md_interrupts && !nemu_journal_requested()) {
    fprintf(stderr, "%s requires --diff-record or --diff-stream-fd\n",
            nemu_md_uart ? "--diff-uart" : (nemu_md_plic ? "--diff-plic" : (nemu_md_clint ? "--diff-clint" : "--diff-interrupts")));
    exit(1);
  }
  if (nemu_plic_input_path && !nemu_md_plic) {
    fprintf(stderr, "--diff-plic-input requires --diff-plic\n");
    exit(1);
  }
  if ((nemu_uart_input_path || nemu_uart_stdin) && !nemu_md_uart) {
    fprintf(stderr, "%s requires --diff-uart\n", nemu_uart_input_path ? "--diff-uart-input" : "--diff-uart-stdin");
    exit(1);
  }
  if (nemu_journal_path && nemu_journal_fd >= 0) {
    fprintf(stderr, "--diff-record and --diff-stream-fd are mutually exclusive\n");
    exit(1);
  }
  if (nemu_journal_requested() && (!batch_requested || diff_so_file || nemu_multidiff_requested)) {
    fprintf(stderr, "--diff-record/--diff-stream-fd requires --batch and no --diff/--diff-mode=multihart\n");
    exit(1);
  }
  if (nemu_multidiff_requested && (!diff_so_file || nemu_threaded || !batch_requested)) {
    fprintf(stderr, "Multihart DiffTest requires --diff, --batch and --smp-backend=rr\n");
    exit(1);
  }
  if (nemu_nr_harts > 1 || nemu_threaded || nemu_multidiff_requested || nemu_journal_requested())
  {
    extern bool ftrace_enabled;
    Assert((!diff_so_file || nemu_multidiff_requested) && !ftrace_enabled && !boot_from_flash &&
           !getenv("RAPT_SUBSYSTEM_TRACE_PREFIX"),
           "Multi-hart execution does not support DiffTest, ftrace or flash/subsystem traces");
  }
#endif
  if (nemu_threaded && !batch_requested)
  {
    fprintf(stderr, "Threaded execution requires --batch; interactive debugging is unsupported\n");
    exit(1);
  }
#ifdef CONFIG_ISA_riscv
  if (riscv_isa_extensions && !riscv_isa_profile_clock_supported(nemu_threaded))
  {
    fprintf(stderr, "RVA23 requires instruction-count timing: CONFIG_TIMER_CYCLE and --smp-backend=rr\n");
    exit(1);
  }
#endif

  /* Set random seed. */
  init_rand();

  /* Open the log file. */
  init_log(log_file);

  /* Initialize memory. */
  init_mem();

  /* Initialize devices. */
#ifdef CONFIG_HAS_DISK
  virtio_blk_set_disk_image(disk_img_file);
  virtio_blk_set_disk_mode(disk_mode);
#endif
#ifdef CONFIG_HAS_SDCARD
  sdcard_set_image(sdcard_img_file);
#endif
  IFDEF(CONFIG_DEVICE, init_device());

  /* Perform ISA dependent initialization. */
  init_isa();

  /* Load the image to memory. This will overwrite the built-in image. */
  long img_size = load_img();

  /* Initialize differential testing.
   * Block SIGVTALRM during difftest init: the spike-diff reference forks
   * `dtc` and reads its pipe with a raw read() that doesn't retry on
   * EINTR. The 60 Hz virtual timer installed by init_device() above can
   * interrupt that read and abort spike's sim_t construction, leaving a
   * partially-built object that segfaults on the next access. */
  {
    sigset_t set_blk, set_old;
    sigemptyset(&set_blk);
    sigaddset(&set_blk, SIGVTALRM);
    sigprocmask(SIG_BLOCK, &set_blk, &set_old);
#ifdef NEMU_HAS_SMP
    if (nemu_multidiff_requested) nemu_multidiff_init(diff_so_file, img_size);
    else
#endif
      init_difftest(diff_so_file, img_size, difftest_port);
    sigprocmask(SIG_SETMASK, &set_old, NULL);
  }
  IFDEF(NEMU_HAS_SMP, nemu_journal_init());

  /* Arm the virtual timer only after difftest init has finished (see
   * device.c). The timer handler list itself was filled during
   * init_device(). */
#if !defined(CONFIG_TARGET_AM) && !defined(CONFIG_TARGET_SHARE) && defined(CONFIG_DEVICE)
  {
    extern void init_alarm();
    init_alarm();
  }
#endif

  /* Initialize the simple debugger. */
  init_sdb();

  IFDEF(CONFIG_ITRACE, init_disasm());

  /* Display welcome message. */
  welcome();
}
#else // CONFIG_TARGET_AM
static long load_img()
{
  extern char bin_start, bin_end;
  size_t size = &bin_end - &bin_start;
  Log("img size = %ld", size);
  memcpy(guest_to_host(RESET_VECTOR), &bin_start, size);
  return size;
}

void am_init_monitor()
{
  init_rand();
  init_mem();
  init_isa();
  load_img();
  IFDEF(CONFIG_DEVICE, init_device());
  welcome();
}
#endif

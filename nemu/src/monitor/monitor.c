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
#include <memory/paddr.h>
#include <device/mmio.h>
#include <inttypes.h>
#include <stdlib.h>
#include <string.h>

extern char *btb_file;
extern long long int max_inst;

void init_rand();
void init_log(const char *log_file);
void init_mem();
void init_difftest(char *ref_so_file, long img_size, int port);
void init_device();
void init_sdb();
void init_disasm();
#ifdef CONFIG_HAS_SERIAL
void serial_set_lf_to_cr(bool enable);
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
  // Log("Exercise: Please remove me in the source code and compile NEMU again.");
  // assert(0);
}

#ifndef CONFIG_TARGET_AM
#include <getopt.h>

void sdb_set_batch_mode();

int boot_from_flash = 0;

static char *log_file = NULL;
static char *diff_so_file = NULL;
static char *img_file = NULL;
static char *disk_img_file = NULL;
static char *sdcard_img_file = NULL;
static int difftest_port = 1234;
#ifdef CONFIG_HAS_DISK
void virtio_blk_set_disk_image(const char *path);
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

typedef struct {
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
  if (desc != NULL && desc[0] != '\0') {
    fprintf(out, "  %s", desc);
  }
  fprintf(out, "\n");
}

static int compare_map_print_entry(const void *lhs_ptr, const void *rhs_ptr) {
  const map_print_entry_t *lhs = (const map_print_entry_t *)lhs_ptr;
  const map_print_entry_t *rhs = (const map_print_entry_t *)rhs_ptr;
  if (lhs->base < rhs->base) {
    return -1;
  }
  if (lhs->base > rhs->base) {
    return 1;
  }
  if (lhs->size < rhs->size) {
    return -1;
  }
  if (lhs->size > rhs->size) {
    return 1;
  }
  return strcmp(lhs->name, rhs->name);
}

static void print_map_entries_sorted(FILE *out, const char *kind,
    map_print_entry_t *entries, size_t count) {
  qsort(entries, count, sizeof(entries[0]), compare_map_print_entry);
  for (size_t i = 0; i < count; i++) {
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
  if (out == NULL) {
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
      {"sdram", CONFIG_SDRAM_BASE, CONFIG_SDRAM_SIZE, "external SDRAM window"},
  };
  print_map_entries_sorted(out, "mem", mem_entries, sizeof(mem_entries) / sizeof(mem_entries[0]));
#ifdef CONFIG_DEVICE
  if (mmio_map_count() > 0) {
    print_mmio_maps(out);
  } else {
    print_configured_mmio_maps(out);
  }
#endif
  fprintf(out, "\n");
}

void usage(int argc, char *argv[])
{
  printf("Usage: %s [OPTION...] IMAGE [args]\n\n", argv[0]);
  printf("Options:\n");
  printf("  -b, --batch              run with batch mode\n");
  printf("  -f, --flash              boot from flash\n");
  printf("  -l, --log=FILE           output log to FILE\n");
  printf("  -d, --diff=REF_SO        run DiffTest with reference REF_SO\n");
  printf("  -p, --port=PORT          run DiffTest with port PORT\n");
  printf("  -e, --elf=ELF_FILE       add ELF_FILE for ftrace\n");
  printf("  -t, --tree=BTB_FILE      add BTB_FILE for rom\n");
  printf("      --disk=DISK_IMAGE    attach a virtio-mmio block image\n");
  printf("      --sdcard=SD_IMAGE    attach a QEMU SDHCI SD-card image\n");
#ifdef CONFIG_HAS_SERIAL
  printf("      --serial-lf-to-cr    translate host LF input to CR for CR-terminated monitors\n");
#endif
  printf("  -m, --maximum=NUM        set the maximum number of instructions to execute\n");
  printf("  -n, --none               do nothing\n");
  printf("      --sig=SPEC           dump RISCOF signature (SPEC=<hex_begin>-<hex_end>:<path>)\n");
  printf("  -h, --help               display this help and exit\n");
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
      {"sdcard", required_argument, NULL, 258},
#ifdef CONFIG_HAS_SERIAL
      {"serial-lf-to-cr", no_argument, NULL, 259},
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
    case 'b':
      sdb_set_batch_mode();
      break;
    case 'f':
      boot_from_flash = 1;
      break;
    case 'p':
      sscanf(optarg, "%d", &difftest_port);
      break;
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
    case 258:
      sdcard_img_file = optarg;
      break;
#ifdef CONFIG_HAS_SERIAL
    case 259:
      serial_set_lf_to_cr(true);
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

  /* Set random seed. */
  init_rand();

  /* Open the log file. */
  init_log(log_file);

  /* Initialize memory. */
  init_mem();

  /* Initialize devices. */
#ifdef CONFIG_HAS_DISK
  virtio_blk_set_disk_image(disk_img_file);
#endif
#ifdef CONFIG_HAS_SDCARD
  sdcard_set_image(sdcard_img_file);
#endif
  IFDEF(CONFIG_DEVICE, init_device());

  /* Perform ISA dependent initialization. */
  init_isa();

  /* Load the image to memory. This will overwrite the built-in image. */
  long img_size = load_img();

  /* Initialize differential testing. */
  init_difftest(diff_so_file, img_size, difftest_port);

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

#include <common.h>
#include <checkpoint.h>
#include <difftest.h>
#include <lightsss.h>
#include <memory.h>
#include <getopt.h>
#include <stdio.h>
#include <string.h>
#include <libgen.h>

/* Directory holding the simulator binary, derived from argv[0]. Per the sim
 * Makefile, BIN lives directly in $(BUILD_DIR) = ./build/$(RAPT_CONFIG), so
 * this is the per-config build dir and the natural home for checkpoint /
 * LightSSS snapshot output. Defaults to "." until parse_args() fills it. */
static char g_build_dir[1024] = ".";

static void compute_build_dir(const char *argv0)
{
  if (argv0 == NULL || argv0[0] == '\0')
    return;
  char buf[1024];
  strncpy(buf, argv0, sizeof(buf) - 1);
  buf[sizeof(buf) - 1] = '\0';
  const char *d = dirname(buf); /* may return a pointer into buf or static storage */
  strncpy(g_build_dir, d, sizeof(g_build_dir) - 1);
  g_build_dir[sizeof(g_build_dir) - 1] = '\0';
}

static const uint32_t img[] = {
    0x00108093, // 80000000: addi ra, ra, 1
    0x00108093, // 80000004: addi ra, ra, 1
    0x00108093, // 80000008: addi ra, ra, 1
    0x00108093, // 8000000c: addi ra, ra, 1
    0x00108093, // 80000010: addi ra, ra, 1
    0x00000117, // 80000014: auipc sp,0x0
    0x00100513, // 80000018: addi 0, zero, 1
    0x00a12023, // 8000001c: sw	a0,0(sp)
    0x00a12023, // 80000020: sw	a0,0(sp)
    0x00a12023, // 80000024: sw	a0,0(sp)
    0x00012483, // 80000028: lw	s1,0(sp)
    0x00012483, // 8000002c: lw	s1,0(sp)
    0x00000513, // 80000030: addi 0, zero, 0
    // ebreak;          0b0000000 00001 00000 000 00000 11100 11;
    0b00000000000100000000000001110011,
};

static const uint32_t img_char_test[] = {
    0x00000117, // 80000000: auipc sp,0x0
    0x0080016f, // 80000004: jal sp, 0x8
    0x04100713, // 80000008: addi a4, zero, 0x41
    0x04100713, // 8000000c: addi a4, zero, 0x41
    0x00000463, // 80000010: beq a0, x0, 0x8
    0x00000117, // 80000014: auipc sp,0x0
    0x00012483, // 80000018: lw	s1,0(sp)
    0x04100713, // 8000001c: addi a4, zero, 0x41
    0x100007b7, // 80000020: lui a5, 0x10000
    0x00000117, // 80000024: auipc sp,0x0
    0x00a00713, // 80000028: addi a4, zero, 0x0a
    0x00a00713, // 8000002c: addi a4, zero, 0x0a
    0x00a00713, // 80000030: addi a4, zero, 0x0a
    0x00a00713, // 80000034: addi a4, zero, 0x0a
    0xdf002117, // 80000038: auipc sp, -135166
    0xffc10113, // 8000003c: addi sp, sp, -4
    0xff410113, // 80000040: addi sp, sp, -12
    0x00a00713, // 80000044: addi a4, zero, 0x0a
    0x00a00713, // 80000048: addi a4, zero, 0x0a
    0x00a00713, // 8000004c: addi a4, zero, 0x0a
    0x00100073, // 80000050: ebreak
};

void isa_parser_elf(char *filename);

extern long long int max_inst;
extern long long int max_timeout;

void sdb_set_batch_mode();

void sdb_set_vcd(bool status);

void sdb_sim_init(int argc, char **argv);

void serial_set_lf_to_cr(bool enable);

static char *log_file = NULL;
static char *diff_so_file = NULL;
static char *img_file = NULL;
static char *mrom_img_file = NULL;
static char *disk_img_file = NULL;
static char *sdcard_img_file = NULL;
static int difftest_port = 1234;
static uint32_t mem_random_delay_max = 0;
static uint32_t mem_random_state = 1;

extern "C" uint32_t npc_mem_random_delay(void)
{
  if (mem_random_delay_max == 0)
    return 0;

  /* xorshift32: deterministic so a failing seed can be replayed exactly. */
  mem_random_state ^= mem_random_state << 13;
  mem_random_state ^= mem_random_state >> 17;
  mem_random_state ^= mem_random_state << 5;
  return mem_random_state % (mem_random_delay_max + 1);
}

long load_file(const char *filename, void *buf)
{
  FILE *fp = fopen(filename, "rb");
  assert(fp != NULL);

  fseek(fp, 0, SEEK_END);
  long size = ftell(fp);

  Log("image: %s, size: %ld", filename, size);
  fflush(stdout);

  fseek(fp, 0, SEEK_SET);
  int ret = fread(buf, size, 1, fp);
  assert(ret == 1);

  fclose(fp);
  return size;
}

static long load_img()
{
  long size;
  // Load image to memory
  if (img_file == NULL)
  {
    Log("No image is given, use default image.");
    memcpy(guest_to_host(MBASE), img, sizeof(img));
    memcpy(guest_to_host(FLASH_BASE), img_char_test, sizeof(img_char_test));
    size = sizeof(img);
  }
  else
  {
    size = load_file(img_file, guest_to_host(MBASE));
    // load_file(img_file, guest_to_host(FLASH_BASE));
    memcpy(guest_to_host(FLASH_BASE), guest_to_host(MBASE), size);
  }

  // Load MROM image
  if (mrom_img_file != NULL)
  {
    Log("Load MROM image from %s", mrom_img_file);
    load_file(mrom_img_file, guest_to_host(MROM_BASE));
  }

  // Initialize the flash
  // memcpy(guest_to_host(FLASH_BASE), img_char_test, sizeof(img_char_test));
  // for (int i = 0; i < 0x1000; i++)
  // {
  //   uint8_t *p = guest_to_host(FLASH_BASE + i);
  //   p[0] = i & 0xff;
  // }
  return size;
}

static uint64_t parse_u64_auto(const char *s)
{
  return strtoull(s, NULL, 0);
}

static void usage(const char *prog)
{
  printf("Usage: %s [OPTION...] IMAGE [args]\n\n", prog);
  printf("Options:\n");
  printf("  -b, --batch              run with batch mode\n");
  printf("  -n, --no-vcd             disable VCD output\n");
  printf("  -r, --mrom=FILE          load MROM image from FILE\n");
  printf("  -l, --log=FILE           output log to FILE\n");
  printf("  -c, --cycle=THRESHOLD    start waveform dump at active-cycle THRESHOLD (continues to end)\n");
  printf("  -i, --instr=THRESHOLD    start waveform dump at instruction THRESHOLD (continues to end)\n");
  printf("  -d, --diff=REF_SO        run DiffTest with reference REF_SO\n");
  printf("  -p, --port=PORT          run DiffTest with port PORT\n");
  printf("  -e, --elf=ELF_FILE       add ELF_FILE for ftrace\n");
  printf("  -m, --maximum=NUM        set the maximum number of instructions to execute\n");
  printf("  -t, --timeout=SECONDS    set wall-clock timeout in seconds\n");
  printf("      --sig=SPEC           dump RISCOF signature (SPEC=<hex_begin>-<hex_end>:<path>)\n");
  printf("      --trap-on-ebreak     don't halt on ebreak; let RTL take the exception\n");
  printf("      --ckpt-save[=DIR]    save checkpoint (arch state + memory) when a ckpt trigger fires\n");
  printf("                           (DIR defaults to <build>/checkpoint)\n");
  printf("      --ckpt-cycle=N       save after N cycles from reset/resume (default 0 if no trigger)\n");
  printf("      --ckpt-instr=N       save after N committed guest instructions from reset/resume\n");
  printf("      --ckpt-pc=HEX        save after first committed instruction at PC HEX\n");
  printf("      --ckpt-save-exit     exit simulator immediately after writing the checkpoint\n");
  printf("      --ckpt-load=DIR      restore architectural state from checkpoint DIR before run\n");
  printf("      --lightsss[=DIR]     LightSSS: fork a snapshot each progress point; on difftest\n");
  printf("                           divergence dump a checkpoint a window behind the failure\n");
  printf("                           into DIR (default <build>/lightsss-snapshot). ON by default\n");
  printf("                           whenever difftest (-d) is enabled.\n");
  printf("      --no-lightsss        disable the LightSSS auto-snapshot (even with difftest on)\n");
  printf("      --disk=FILE          load FILE as virtio-mmio block disk image\n");
  printf("      --sdcard=FILE        load FILE as LiteX SPI SD-card image\n");
  printf("      --serial-lf-to-cr    translate host LF input to CR for CR-terminated monitors\n");
  printf("      --mem-random-delay=N add 0..N random wait cycles to each AXI memory beat\n");
  printf("      --mem-random-seed=N  set reproducible random-delay seed (default 1)\n");
  printf("  -h, --help               display this help and exit\n");
  printf("\n");
  print_nsim_memory_map(stdout);
}

static int parse_args(int argc, char *argv[])
{
  const struct option table[] = {
      {"help", no_argument, NULL, 'h'},
      {"batch", no_argument, NULL, 'b'},
      {"no-vcd", no_argument, NULL, 'n'},
      {"mrom", required_argument, NULL, 'r'},
      {"log", required_argument, NULL, 'l'},
      {"cycle", required_argument, NULL, 'c'},
      {"instr", required_argument, NULL, 'i'},
      {"diff", required_argument, NULL, 'd'},
      {"port", required_argument, NULL, 'p'},
      {"elf", required_argument, NULL, 'e'},
      {"maximum", required_argument, NULL, 'm'},
      {"timeout", required_argument, NULL, 't'},
      {"sig", required_argument, NULL, 256},
      {"trap-on-ebreak", no_argument, NULL, 257},
      {"ckpt-save", optional_argument, NULL, 258},
      {"ckpt-cycle", required_argument, NULL, 259},
      {"ckpt-save-exit", no_argument, NULL, 260},
      {"ckpt-load", required_argument, NULL, 261},
      {"ckpt-instr", required_argument, NULL, 262},
      {"ckpt-pc", required_argument, NULL, 263},
      {"disk", required_argument, NULL, 264},
      {"sdcard", required_argument, NULL, 265},
      {"serial-lf-to-cr", no_argument, NULL, 266},
      {"lightsss", optional_argument, NULL, 267},
      {"no-lightsss", no_argument, NULL, 268},
      {"mem-random-delay", required_argument, NULL, 269},
      {"mem-random-seed", required_argument, NULL, 270},
      {0, 0, NULL, 0},
  };
  int o;
  size_t cycle_threshold = 0, instr_threshold = 0;
  const char *ckpt_save_dir = NULL;
  bool ckpt_save_requested = false;
  const char *ckpt_load_dir = NULL;
  const char *lightsss_dir = NULL;
  bool lightsss_on = false;
  bool lightsss_off = false;
  compute_build_dir(argv[0]);
  uint64_t ckpt_save_cycle = 0;
  uint64_t ckpt_save_instr = 0;
  word_t ckpt_save_pc = 0;
  bool ckpt_save_has_cycle = false;
  bool ckpt_save_has_instr = false;
  bool ckpt_save_has_pc = false;
  bool ckpt_save_exit = false;
  if (argc == 1)
  {
    usage(argv[0]);
    exit(0);
  }
  while ((o = getopt_long(argc, argv, "-hbnr:l:c:i:d:p:e:m:t:", table, NULL)) != -1)
  {
    switch (o)
    {
    case 'b':
      sdb_set_batch_mode();
      break;
    case 'n':
      sdb_set_vcd(false);
      break;
    case 'r':
      mrom_img_file = optarg;
      break;
    case 'l':
      log_file = optarg;
      break;
    case 'c':
      cycle_threshold = strtoull(optarg, NULL, 0);
      break;
    case 'i':
      instr_threshold = strtoull(optarg, NULL, 0);
      break;
    case 'd':
#ifdef CONFIG_DIFFTEST
      diff_so_file = optarg;
#else
      /* Difftest is compiled out: ignore the reference shared object so we do
       * not spuriously enable LightSSS (which keys off diff_so_file != NULL).
       * The Makefile always passes -d for convenience regardless of config. */
      (void)optarg;
#endif
      break;
    case 'p':
      sscanf(optarg, "%d", &difftest_port);
      break;
    case 'e':
      isa_parser_elf(optarg);
      break;
    case 'm':
      sscanf(optarg, "%lld", &max_inst);
      break;
    case 't':
      sscanf(optarg, "%lld", &max_timeout);
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
    case 257:
    {
      void sdb_set_trap_on_ebreak(bool v);
      sdb_set_trap_on_ebreak(true);
      break;
    }
    case 258:
      ckpt_save_dir = optarg; /* NULL when given as bare --ckpt-save */
      ckpt_save_requested = true;
      break;
    case 259:
      ckpt_save_cycle = parse_u64_auto(optarg);
      ckpt_save_has_cycle = true;
      break;
    case 260:
      ckpt_save_exit = true;
      break;
    case 261:
      ckpt_load_dir = optarg;
      break;
    case 262:
      ckpt_save_instr = parse_u64_auto(optarg);
      ckpt_save_has_instr = true;
      break;
    case 263:
      ckpt_save_pc = (word_t)parse_u64_auto(optarg);
      ckpt_save_has_pc = true;
      break;
    case 264:
      disk_img_file = optarg;
      break;
    case 265:
      sdcard_img_file = optarg;
      break;
    case 266:
      serial_set_lf_to_cr(true);
      break;
    case 267:
      lightsss_on = true;
      lightsss_dir = optarg; /* NULL when given as bare --lightsss */
      break;
    case 268:
      lightsss_off = true;
      break;
    case 269:
    {
      uint64_t delay = parse_u64_auto(optarg);
      if (delay >= 0xfffff)
      {
        printf("ERROR: --mem-random-delay must be less than 1048575 cycles\n");
        exit(1);
      }
      mem_random_delay_max = (uint32_t)delay;
      break;
    }
    case 270:
      mem_random_state = (uint32_t)parse_u64_auto(optarg);
      if (mem_random_state == 0)
        mem_random_state = 1;
      break;
    case 1:
      img_file = optarg;
      break;
    default:
      usage(argv[0]);
      exit(0);
    }
  }
  void cpu_exec_set_threshold(uint64_t cycle, uint64_t inst);
  cpu_exec_set_threshold(cycle_threshold, instr_threshold);
  if (mem_random_delay_max != 0)
    Log("AXI memory random delay enabled: 0..%u cycles, seed=%u",
        mem_random_delay_max, mem_random_state);
  static char ckpt_default_dir[1100];
  if (ckpt_save_requested)
  {
    if (ckpt_save_dir == NULL)
    {
      snprintf(ckpt_default_dir, sizeof(ckpt_default_dir), "%s/checkpoint", g_build_dir);
      ckpt_save_dir = ckpt_default_dir;
    }
    checkpoint_configure_save(ckpt_save_has_cycle, ckpt_save_cycle,
                              ckpt_save_has_instr, ckpt_save_instr,
                              ckpt_save_has_pc, ckpt_save_pc,
                              ckpt_save_dir, ckpt_save_exit);
  }
  /* LightSSS is ON by default whenever difftest is active (that is exactly the
   * configuration that hits deep divergences), unless --no-lightsss was given.
   * It can also be enabled standalone via --lightsss. */
  if (!lightsss_off && (lightsss_on || diff_so_file != NULL))
  {
    static char lightsss_default_dir[1100];
    if (lightsss_dir == NULL)
    {
      snprintf(lightsss_default_dir, sizeof(lightsss_default_dir),
               "%s/lightsss-snapshot", g_build_dir);
      lightsss_dir = lightsss_default_dir;
    }
    lightsss_configure(lightsss_dir);
  }
  /* ckpt_load_dir handling is deferred -- see init_monitor() below. */
  if (ckpt_load_dir != NULL)
  {
    /* Stash via a static so init_monitor can pick it up after load_img(). */
    extern const char *_pending_ckpt_load_dir;
    _pending_ckpt_load_dir = ckpt_load_dir;
  }
  return 0;
}

const char *_pending_ckpt_load_dir = NULL;

void init_monitor(int argc, char *argv[])
{
  parse_args(argc, argv);

  long img_size = load_img();

  void virtio_blk_set_disk_image(const char *path);
  virtio_blk_set_disk_image(disk_img_file);
  void litex_spi_set_image(const char *path);
  litex_spi_set_image(sdcard_img_file);

  /* Apply checkpoint memory load AFTER load_img() so the captured snapshot
   * overrides any image just loaded. The MROM trampoline written here will
   * survive into RTL execution because mrom_read() reads from the same host
   * buffer that checkpoint_configure_load() populated. */
  if (_pending_ckpt_load_dir != NULL)
  {
    checkpoint_configure_load(_pending_ckpt_load_dir);
  }

  sdb_sim_init(argc, argv);

  /* RTL is now post-reset and npc.* pointers are valid. Inject GPRs/CSRs
   * into the live register file. The MROM trampoline (already in mrom
   * buffer) will be fetched on first cycle and mret to ckpt_pc. */
  checkpoint_inject_after_reset();

  init_mem();

#ifdef CONFIG_DIFFTEST
  init_difftest(diff_so_file, img_size, difftest_port);
#endif

#if defined(CONFIG_ITRACE)
  void init_disasm();
  init_disasm();
#endif
}
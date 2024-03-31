#include <common.h>
#include <difftest.h>
#include <memory.h>
#include <getopt.h>
#include <stdio.h>
#include <string.h>

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
    0x100007b7, // 0x80000000: lui a5, 0x10000
    0x04100713, // 0x80000004: addi a4, zero, 0x41
    0x00e78023, // 0x80000008: sw a4, 0(a5)
    0x05a00713, // 0x80000004: addi a4, zero, 0x5a
    0x00e78023, // 0x80000008: sw a4, 0(a5)
    0x00a00713, // 0x8000000c: addi a4, zero, 0x0a
    0x00e78023, // 0x80000010: sw a4, 0(a5)
    0x00100073, // 0x80000014: ebreak
};

void isa_parser_elf(char *filename);

void sdb_set_batch_mode();

void sdb_set_vcd(bool status);

void sdb_sim_init(int argc, char **argv);

void init_disasm(const char *triple);

static char *log_file = NULL;
static char *diff_so_file = NULL;
static char *img_file = NULL;
static char *mrom_img_file = NULL;
static int difftest_port = 1234;

long load_file(const char *filename, void *buf)
{
  FILE *fp = fopen(filename, "rb");
  assert(fp != NULL);

  fseek(fp, 0, SEEK_END);
  long size = ftell(fp);

  Log("image: %s, size: %ld", filename, size);

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

static int parse_args(int argc, char *argv[])
{
  const struct option table[] = {
      {"mrom", required_argument, NULL, 'm'},
      {"batch", no_argument, NULL, 'b'},
      {"no-vcd", no_argument, NULL, 'n'},
      {"log", required_argument, NULL, 'l'},
      {"diff", required_argument, NULL, 'd'},
      {"port", required_argument, NULL, 'p'},
      {"elf", required_argument, NULL, 'e'},
      {"help", no_argument, NULL, 'h'},
      {0, 0, NULL, 0},
  };
  int o;
  while ((o = getopt_long(argc, argv, "-bhnm:l:d:p:e:", table, NULL)) != -1)
  {
    switch (o)
    {
    case 'm':
      mrom_img_file = optarg;
      break;
    case 'b':
      sdb_set_batch_mode();
      break;
    case 'n':
      sdb_set_vcd(false);
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
    case 1:
      img_file = optarg;
      return 0;
    default:
      printf("Usage: %s [OPTION...] IMAGE [args]\n\n", argv[0]);
      printf("Options:\n");
      printf("\t-m,--mrom=FILE          load MROM image from FILE\n");
      printf("\t-b,--batch              run with batch mode\n");
      printf("\t-n,--no-vcd             disable VCD output\n");
      printf("\t-l,--log=FILE           output log to FILE\n");
      printf("\t-d,--diff=REF_SO        run DiffTest with reference REF_SO\n");
      printf("\t-p,--port=PORT          run DiffTest with port PORT\n");
      printf("\t-e,--elf=ELF_FILE       add ELF_FILE for ftrace\n");
      printf("\n");
      exit(0);
    }
  }
  return 0;
}

void init_monitor(int argc, char *argv[])
{
  parse_args(argc, argv);

  long img_size = load_img();

  sdb_sim_init(argc, argv);

  init_difftest(diff_so_file, img_size, difftest_port);

  init_disasm("riscv32");
}
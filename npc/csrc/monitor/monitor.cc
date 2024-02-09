#include <common.h>
#include <difftest.h>
#include <mem.h>
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

void isa_parser_elf(char *filename);

void sdb_set_batch_mode();

void sdb_sim_init(int argc, char **argv);

void init_disasm(const char *triple);

static char *log_file = NULL;
static char *diff_so_file = NULL;
static char *img_file = NULL;
static int difftest_port = 1234;

static long load_img()
{
  if (img_file == NULL)
  {
    memcpy(guest_to_host(MBASE), img, sizeof(img));
    return sizeof(img);
  }

  FILE *fp = fopen(img_file, "rb");
  assert(fp != NULL);

  fseek(fp, 0, SEEK_END);
  long size = ftell(fp);

  printf("image: %s, size: %ld\n", img_file, size);

  fseek(fp, 0, SEEK_SET);
  int ret = fread(guest_to_host(MBASE), size, 1, fp);
  assert(ret == 1);

  fclose(fp);
  return size;
}

static int parse_args(int argc, char *argv[])
{
  const struct option table[] = {
      {"batch", no_argument, NULL, 'b'},
      {"log", required_argument, NULL, 'l'},
      {"diff", required_argument, NULL, 'd'},
      {"port", required_argument, NULL, 'p'},
      {"elf", required_argument, NULL, 'e'},
      {"help", no_argument, NULL, 'h'},
      {0, 0, NULL, 0},
  };
  int o;
  while ((o = getopt_long(argc, argv, "-bhl:d:p:e:", table, NULL)) != -1)
  {
    switch (o)
    {
    case 'b':
      sdb_set_batch_mode();
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
      printf("\t-b,--batch              run with batch mode\n");
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

  sdb_sim_init(argc, argv);

  long img_size = load_img();

  init_difftest(diff_so_file, img_size, difftest_port);

  init_disasm("riscv32");
}
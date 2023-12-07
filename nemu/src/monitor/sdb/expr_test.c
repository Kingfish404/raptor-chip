#include <common.h>
#include "sdb.h"

void init_regex();

void expr_tests()
{
  init_regex();
  bool success = true;
  FILE *fp = fopen("./input64", "r");
  if (fp == NULL)
  {
    printf("Error: file not found!\n");
    exit(1);
  }
  fseek(fp, 0, SEEK_END);
  long size = ftell(fp);
  char *test_data = malloc(size);

  fseek(fp, 0, SEEK_SET);
  int ret = fread(test_data, size, 1, fp);
  assert(ret == 1);
  fclose(fp);

  char *line = NULL, *context = NULL;
  for (
      line = strtok_r(test_data, "\n", &context);
      line;
      line = strtok_r(NULL, "\n", &context))
  {
    char *idx = strchr(line, ' ');
    word_t gt = strtoull(line, &idx, 0);
    success = true;
    word_t data = expr(idx + 1, &success);
    printf("gt: " FMT_WORD ", " FMT_WORD ", data: " FMT_WORD ", " FMT_WORD "\n", gt, gt, data, data);
    assert(gt == data);
  }
  exit(0);
}
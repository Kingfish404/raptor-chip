#include <common.h>
#include "monitor/sdb/sdb.h"

void init_regex();

void test_expr() {
  init_regex();
  bool success = true;
  FILE *fp = fopen("./input-advance", "r");
  fseek(fp, 0, SEEK_END);
  long size = ftell(fp);
  char *test_data = malloc(size);

  fseek(fp, 0, SEEK_SET);
  int ret = fread(test_data, size, 1, fp);
  assert(ret == 1);
  fclose(fp);

  char *line=NULL, *context=NULL;
  for (
    line = strtok_r(test_data, "\n", &context);
    line;
    line = strtok_r(NULL, "\n", &context)) {
    char *idx = strchr(line, ' ');
    word_t gt = strtoll(line, &idx, 0);
    success = true;
    word_t data = expr(idx + 1, &success);
    if (success) {
      printf("0x%08llx\n", data);
    }
    printf("%llu, %llu\n", gt, data);
    assert(gt == data);
  }
  exit(0);
}
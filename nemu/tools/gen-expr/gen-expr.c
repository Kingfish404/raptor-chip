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

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <assert.h>
#include <string.h>

// this should be enough
static char buf[65536] = {};
static uint32_t buf_pointer = 0;
static char code_buf[65536 + 128] = {}; // a little larger than `buf`
static char ops[] = "+-*/";
static char *code_format =
"#include <stdio.h>\n"
"int main() { "
"  unsigned result = %s; "
"  printf(\"%%u\", result); "
"  return 0; "
"}";

uint32_t choose(uint32_t n) {
  return rand() % n;
}

void gen(char c){
  buf[buf_pointer] = c;
  buf_pointer++;
}

void gen_num() {
  gen('1' + choose(9));
  int len = choose(4);
  for (size_t i = 0; i < len; i++)
  {
    gen('0' + choose(10));
  }
  gen('u');
}

void gen_space() {
  int len = choose(5);
  for (size_t i = 0; i < len; i++)
  {
    gen(' ');
  }
}

void gen_rand_op() {
  gen(ops[choose(sizeof(ops)-1)]);
}

static void gen_rand_expr() {
  if (buf_pointer > 16){
    return gen_num();
  }
  switch (choose(3))
  {
  case 0:
    gen_num();
    break;
  case 1:
    gen('('); gen_space(); gen_rand_expr();gen_space() ; gen(')');
    break;
  default:
    gen_rand_expr(); gen_space() ;gen_rand_op(); gen_space() ;gen_rand_expr();
    break;
  }
}

int main(int argc, char *argv[]) {
  int seed = time(0);
  srand(seed);
  int loop = 1;
  if (argc > 1) {
    sscanf(argv[1], "%d", &loop);
  }
  int i;
  for (i = 0; i < loop; i ++) {
    buf_pointer = 0;
    gen_rand_expr();
    buf[buf_pointer] = '\0';

    sprintf(code_buf, code_format, buf);

    FILE *fp = fopen("/tmp/.code.c", "w");
    assert(fp != NULL);
    fputs(code_buf, fp);
    fclose(fp);

    int ret = system("gcc /tmp/.code.c -o /tmp/.expr");
    if (ret != 0) continue;

    unsigned results[3];
    for (size_t j = 0; j < 3; j++)
    {
      fp = popen("/tmp/.expr", "r");
      assert(fp != NULL);

      int result;
      ret = fscanf(fp, "%d", &result);
      results[j] = result;
      pclose(fp);
    }
    if (results[0] != results[1] || results[1] != results [2]) {
      continue;
    }
    printf("%u %s\n", results[0], buf);
    if (i % 100 == 0){
      fflush(stdout);
    }
  }
  return 0;
}

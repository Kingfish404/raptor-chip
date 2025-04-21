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
#include <cpu/cpu.h>
#include <memory/vaddr.h>
#include <readline/readline.h>
#include <readline/history.h>
#include "sdb.h"

static int is_batch_mode = false;

void init_regex();
void init_wp_pool();

/* We use the `readline' library to provide more flexibility to read from stdin. */
static char* rl_gets() {
  static char *line_read = NULL;

// #ifndef CONFIG_TARGET_SHARE
  if (line_read) {
    free(line_read);
    line_read = NULL;
  }

  line_read = readline("(nemu) ");

  if (line_read && *line_read) {
    add_history(line_read);
  }
// #endif

  return line_read;
}

static int cmd_c(char *args) {
  cpu_exec(-1);
  return 0;
}


static int cmd_q(char *args) {
  set_nemu_state(NEMU_QUIT, cpu.pc, -1);
  return -1;
}

static int cmd_info(char *args);

static int cmd_si(char *args) {
  int n = 1;
  if (args != NULL) {
    sscanf(args, "%d", &n);
  }
  cpu_exec(n);
  cmd_info("i");
  cmd_info("r");
  return 0;
}

static int cmd_info(char *args) {
  if (args == NULL) {
    printf("No argument given.\n");
    return 0;
  }
  while (args[0] == ' ') {
    args++;
  }
  switch (args[0])    
  {
  case 'r':
    isa_reg_display();
    break;
  case 'w':
    wp_show();
    break;
  case 'i':
    #ifdef CONFIG_ITRACE
      cpu_show_itrace();
    #else
      printf("ITRACE is not enabled.\n");
    #endif
    break;
  case 'f':
    cpu_show_ftrace();
    break;
  default:
    printf("Unknown argument '%s'.\n", args);
    break;
  }
  return 0;
}

static int cmd_x(char *args) {
  char *arg = strtok(args, " ");
  if (arg == NULL){
    printf("No argument given.\n");
    return 0;
  }
  char *e = strtok(NULL, " ");
  if (e == NULL){
    printf("Require second argument.\n");
    return 0;
  }

  int n;
  long long addr;
  bool success = true;
  sscanf(arg, "%d", &n);
  addr = expr(e, &success);
  if (!success) {
    printf("Invalid arg: %s, expr: %llx\n", args, addr);
    return 0;
  }

  vaddr_show(addr, n);
  return 0;
}

static int cmd_p(char *args) {
  if (args == NULL){
    printf("No argument given.\n");
    return 0;
  }
  bool success = true;
  word_t data = expr(args, &success);
  if (success) {
    printf(FMT_WORD "\n", data);
  }
  else {
    printf("Invalid arg: %s, expr: " FMT_WORD "\n", args, data);
  }
  return 0;
}

static int cmd_w(char *args) {
  if (args == NULL){
    printf("No argument given.\n");
    return 0;
  }
  bool success = true;
  wp_add(args, &success);
  if (!success) {
    printf("Invalid arg: %s\n", args);
  }
  return 0;
}

static int cmd_d(char *args) {
  if (args == NULL){
    printf("No argument given.\n");
    return 0;
  }
  int n;
  sscanf(args, "%d", &n);
  bool success = true;
  wp_del(n, &success);
  if (!success) {
    printf("Invalid arg: %d\n", n);
  }
  return 0;
}

static int cmd_help(char *args);

static struct {
  const char *name;
  const char *description;
  int (*handler) (char *);
} cmd_table [] = {
  { "help", "Display information about all supported commands", cmd_help },
  { "c", "Continue the execution of the program", cmd_c },
  { "rs", "Run the execution of the program (same to `c`)", cmd_c },
  { "q", "Exit NEMU", cmd_q },
  { "si", "si/s [N]\tExecute 'N' instructions step by step. When N is not given, the default is 1.", cmd_si },
  { "info", "info/i SUBCMD\tPrint: register state by 'i r'. watchpoint information by 'i w'. instruction flow by 'i i'. function flow by 'i f", cmd_info },
  { "x", "x N EXPR\tScan 'N' continue 4 bytes, using 'EXPR' as start address.", cmd_x},
  { "p", "p EXPR\tProcess and show the result of 'EXPR'.", cmd_p},
  { "w", "w EXPR\tPause program when the result of 'EXPR changed.", cmd_w},
  { "d", "d N\t\tDelete watchpoint which's id is 'N'.", cmd_d},
};

#define NR_CMD ARRLEN(cmd_table)

static int cmd_help(char *args) {
  /* extract the first argument */
  char *arg = strtok(NULL, " ");
  int i;

  if (arg == NULL) {
    /* no argument given */
    for (i = 0; i < NR_CMD; i ++) {
      printf("  %s\t- %s\n", cmd_table[i].name, cmd_table[i].description);
    }
  }
  else {
    for (i = 0; i < NR_CMD; i ++) {
      if ((strcmp(arg, cmd_table[i].name) == 0) ||
          (strlen(arg) == 1 && arg[0] == cmd_table[i].name[0])) {
        printf("%s - %s\n", cmd_table[i].name, cmd_table[i].description);
        return 0;
      }
    }
    printf("Unknown command '%s'\n", arg);
  }
  return 0;
}

void sdb_set_batch_mode() {
  is_batch_mode = true;
}

void sdb_mainloop() {
  if (is_batch_mode) {
    cmd_c(NULL);
    return;
  }

  for (char *str; (str = rl_gets()) != NULL; ) {
    char *str_end = str + strlen(str);

    /* extract the first token as the command */
    char *cmd = strtok(str, " ");
    if (cmd == NULL) { continue; }

    /* treat the remaining string as the arguments,
     * which may need further parsing
     */
    char *args = cmd + strlen(cmd) + 1;
    if (args >= str_end) {
      args = NULL;
    }

#ifdef CONFIG_DEVICE
    extern void sdl_clear_event_queue();
    sdl_clear_event_queue();
#endif

    int i;
    for (i = 0; i < NR_CMD; i ++) {
      if ((strcmp(cmd, cmd_table[i].name) == 0) ||
          (strlen(cmd) == 1 && cmd[0] == cmd_table[i].name[0])) {
        if (cmd_table[i].handler(args) < 0) { return; }
        break;
      }
    }

    if (i == NR_CMD) { printf("Unknown command '%s'\n", cmd); }
  }
}

void init_sdb() {
  /* Compile the regular expressions. */
  init_regex();

  /* Initialize the watchpoint pool. */
  init_wp_pool();
}

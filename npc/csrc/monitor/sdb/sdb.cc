#include <common.h>
#include <cpu.h>
#include <readline/readline.h>
#include <readline/history.h>
#include "Vtop.h"
#include "Vtop___024root.h"
#include "Vtop__Dpi.h"
#include "verilated.h"
#include "verilated_vcd_c.h"

extern char *regs[];
extern uint64_t g_timer;
extern uint64_t g_nr_guest_inst;

NPCState npc = {NPC_RUNNING, NULL, NULL, NULL};

VerilatedContext *contextp = NULL;
Vtop *top = NULL;
VerilatedVcdC *tfp = NULL;

static bool is_batch_mode = false;

/* We use the `readline' library to provide more flexibility to read from stdin. */
static char *rl_gets()
{
  static char *line_read = NULL;

  if (line_read)
  {
    free(line_read);
    line_read = NULL;
  }

  line_read = readline("(npc) ");

  if (line_read && *line_read)
  {
    add_history(line_read);
  }

  return line_read;
}

void reset(Vtop *top, int n)
{
  top->rst = 1;
  while (n-- > 0)
  {
    top->clk = 0;
    top->eval();
    top->clk = 1;
    top->eval();
  }
  top->rst = 0;
}

extern "C" void npc_exu_ebreak()
{
  contextp->gotFinish(true);
  npc.state = NPC_END;
}

extern "C" void npc_illegal_inst()
{
  contextp->gotFinish(true);
  if (npc.state == NPC_ABORT)
  {
    return;
  }
  npc.state = NPC_ABORT;
}

void sdb_set_batch_mode()
{
  is_batch_mode = true;
}

int cmd_c(char *args)
{
  cpu_exec(-1);
  return 0;
}

int cmd_info(char *args)
{
  reg_display(GPR_SIZE);
  return 0;
}

int cmd_q(char *args)
{
  npc.state = NPC_QUIT;
  return -1;
}

int cmd_si(char *args)
{
  int n = 1;
  if (args != NULL)
  {
    sscanf(args, "%d", &n);
  }
  cpu_exec(n);
  return 0;
}

int cmd_help(char *args);

static struct
{
  const char *name;
  const char *description;
  int (*handler)(char *);
} cmd_table[] = {
    {"help", "Display information about all supported commands", cmd_help},
    {"c", "Continue the execution of the program", cmd_c},
    {"si", "Execute N instructions step by step", cmd_si},
    {"info", "Generic command for showing things about the program being debugged", cmd_info},
    {"q", "Exit NPC", cmd_q},
};

int cmd_help(char *args)
{
  printf("The following commands are supported:\n");
  for (int i = 0; i < ARRLEN(cmd_table); i++)
  {
    printf("%s - %s\n", cmd_table[i].name, cmd_table[i].description);
  }
  return 0;
}

void sdb_mainloop()
{
  if (is_batch_mode)
  {
    cmd_c(NULL);
    return;
  }

  for (char *str; (str = rl_gets()) != NULL;)
  {
    char *str_end = str + strlen(str);
    char *cmd = strtok(str, " ");
    if (cmd == NULL)
    {
      continue;
    }

    char *args = cmd + strlen(cmd) + 1;
    if (args >= str_end)
    {
      args = NULL;
    }

    int i;
    for (i = 0; i < ARRLEN(cmd_table); i++)
    {
      if (
          (strcmp(cmd, cmd_table[i].name) == 0) ||
          (strlen(cmd) == 1 && cmd[0] == cmd_table[i].name[0]))
      {
        if (cmd_table[i].handler(args) < 0)
        {
          return;
        }
        break;
      }
    }
    if (i == ARRLEN(cmd_table))
    {
      printf("Unknown command '%s'\n", cmd);
    }
  }
}

void sdb_sim_init(int argc, char **argv)
{
  contextp = new VerilatedContext;
  contextp->commandArgs(argc, argv);
  top = new Vtop{contextp};
  Verilated::traceEverOn(true);
  tfp = new VerilatedVcdC;
  top->trace(tfp, 99);
  tfp->open("npc.vcd");
  npc.gpr = (word_t *)&(top->rootp->top__DOT__regs__DOT__rf);
  npc.pc = (uint32_t *)&(top->rootp->top__DOT__pc);
  npc.ret = npc.gpr + reg_str2idx("a0");
  npc.state = NPC_RUNNING;

  top->inst = 0x37; // lui x0, 0x0
  reset(top, 1);
}

void sdb_sim_end()
{
  tfp->close();

  delete tfp;
  delete top;
  delete contextp;
}

void engine_start()
{
  sdb_mainloop();
  if (*npc.ret != 0)
  {
    printf("a0 = " FMT_RED(FMT_WORD) "\n", *npc.ret);
  }
  if (npc.state == NPC_ABORT)
  {
    cpu_show_itrace();
    reg_display(GPR_SIZE);
  }
  Log(FMT_BLUE("nr_inst = %llu, time = %llu (ns)"), g_nr_guest_inst, g_timer);
  Log("%s at pc = " FMT_WORD_NO_PREFIX ", inst: " FMT_WORD_NO_PREFIX,
      ((*npc.ret) == 0 && npc.state != NPC_ABORT
           ? FMT_GREEN("HIT GOOD TRAP")
           : FMT_RED("HIT BAD TRAP")),
      (*npc.pc), top->inst);
  sdb_sim_end();
}
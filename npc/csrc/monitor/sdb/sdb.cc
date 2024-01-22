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
void difftest_skip_ref();

NPCState npc = {
    .state = NPC_RUNNING,
    .gpr = NULL,
    .ret = NULL,
    .pc = NULL,

    .mcause = NULL,
    .mtvec = NULL,
    .mepc = NULL,
    .mstatus = NULL,

    .inst = NULL,

    .bus_freq = NULL,
};

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
  top->reset = 1;
  while (n-- > 0)
  {
    top->clock = 0;
    top->eval();
    top->clock = 1;
    top->eval();
  }
  top->reset = 0;
}

void npc_abort()
{
  contextp->gotFinish(true);
  npc.state = NPC_ABORT;
}

extern "C" void npc_exu_ebreak()
{
  contextp->gotFinish(true);
  printf("EBREAK at pc = " FMT_WORD_NO_PREFIX "\n", *npc.pc);
  npc.state = NPC_END;
}

void npc_difftest_skip_ref()
{
  difftest_skip_ref();
}

extern "C" void npc_illegal_inst()
{
  contextp->gotFinish(true);
  Error("Illegal instruction at pc = " FMT_WORD_NO_PREFIX, *npc.pc);
  npc_abort();
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
  if (args == NULL)
  {
    reg_display(GPR_SIZE);
    return 0;
  }
  while (args[0] == ' ')
  {
    args++;
  }
  switch (args[0])
  {
  case 'r':
    reg_display();
    break;
  case 'i':
    cpu_show_itrace();
    break;
  default:
    printf("Unknown argument '%s'.\n", args);
    break;
  }
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
    {"help", "h\tDisplay information about all supported commands", cmd_help},
    {"c", "c\tContinue the execution of the program", cmd_c},
    {"si", "si/s [N] \tExecute N instructions step by step", cmd_si},
    {"info", "info/i [ARG]\tGeneric command for showing things about regs (r), instruction trace (i)", cmd_info},
    {"q", "q\tExit NPC", cmd_q},
};

int cmd_help(char *args)
{
  printf("The following commands are supported:\n");
  for (int i = 0; i < ARRLEN(cmd_table); i++)
  {
    printf("%s\t- %s\n", cmd_table[i].name, cmd_table[i].description);
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
#ifdef CONFIG_WTRACE
  tfp = new VerilatedVcdC;
  top->trace(tfp, 99);
  tfp->open("npc.vcd");
#endif
  npc.gpr = (word_t *)&(top->rootp->top__DOT__regs__DOT__rf);
  npc.pc = (uint32_t *)&(top->rootp->top__DOT__pc);
  npc.ret = npc.gpr + reg_str2idx("a0");
  npc.state = NPC_RUNNING;
  word_t *csr = (word_t *)&(top->rootp->top__DOT__exu__DOT__csr__DOT__csr);
  npc.mstatus = csr + CSR_MSTATUS;
  npc.mcause = csr + CSR_MCAUSE;
  npc.mepc = csr + CSR_MEPC;
  npc.mtvec = csr + CSR_MTVEC;

  // for difftest
  npc.inst = (uint32_t *)&(top->rootp->top__DOT__ifu__DOT__inst_ifu);

  reset(top, 1);
  if (tfp)
  {
    tfp->dump(contextp->time());
  }
  contextp->timeInc(1);
}

void engine_start()
{
  sdb_mainloop();

  if (tfp)
  {
    tfp->close();
    delete tfp;
  }

  delete top;
  delete contextp;
}
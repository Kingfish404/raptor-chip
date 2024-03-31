#include <common.h>
#include <cpu.h>
#include <readline/readline.h>
#include <readline/history.h>
#include <npc_verilog.h>
#include <verilated.h>
#include <verilated_vcd_c.h>
#ifdef CONFIG_NVBoard
#include <nvboard.h>
#endif

extern char *regs[];
void difftest_skip_ref();
void difftest_should_diff_mem();

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

    .soc_sram = NULL,
};

VerilatedContext *contextp = NULL;
TOP_NAME *top = NULL;
VerilatedVcdC *tfp = NULL;

static bool is_batch_mode = false;
static bool enable_vcd = true;

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

void reset(TOP_NAME *top, int n)
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

void npc_difftest_mem_diff()
{
  difftest_should_diff_mem();
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

void soc_show_sram()
{
  if (npc.soc_sram != NULL)
  {
    for (size_t i = 0; i < 1024; i++)
    {
      printf("%02x ", npc.soc_sram[i]);
    }
    printf("\n");
  }
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
  case 's':
    soc_show_sram();
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

void sdb_set_vcd(bool status)
{
  enable_vcd = status;
}

void sdb_sim_init(int argc, char **argv)
{
  contextp = new VerilatedContext;
  contextp->commandArgs(argc, argv);
  top = new TOP_NAME{contextp};
  Verilated::traceEverOn(true);
#ifdef CONFIG_WTRACE
  if (enable_vcd)
  {
    tfp = new VerilatedVcdC;
    top->trace(tfp, 99);
    tfp->open("npc.vcd");
  }
#endif
  verilog_connect(top, &npc);

  reset(top, 1);
  if (tfp)
  {
    tfp->dump(contextp->time());
  }
  contextp->timeInc(1);

#ifdef CONFIG_NVBoard
#define VERILOG_PREFIX_PERIP top->rootp->ysyxSoCFull__DOT__asic__DOT__
  nvboard_bind_pin(
      &CONCAT(VERILOG_PREFIX_PERIP, lgpio__DOT__mgpio__DOT__gpio),
      16, LD15, LD14, LD13, LD12, LD11, LD10, LD9, LD8, LD7, LD6, LD5, LD4, LD3, LD2, LD1, LD0);

  nvboard_bind_pin(
      &CONCAT(VERILOG_PREFIX_PERIP, lgpio__DOT__mgpio__DOT__switch),
      16, SW15, SW14, SW13, SW12, SW11, SW10, SW9, SW8, SW7, SW6, SW5, SW4, SW3, SW2, SW1, SW0);

  nvboard_bind_pin(&CONCAT(VERILOG_PREFIX_PERIP, lgpio__DOT__mgpio__DOT__seg0), 8, SEG0A, SEG0B, SEG0C, SEG0D, SEG0E, SEG0F, SEG0G, DEC0P);
  nvboard_bind_pin(&CONCAT(VERILOG_PREFIX_PERIP, lgpio__DOT__mgpio__DOT__seg1), 8, SEG1A, SEG1B, SEG1C, SEG1D, SEG1E, SEG1F, SEG1G, DEC1P);
  nvboard_bind_pin(&CONCAT(VERILOG_PREFIX_PERIP, lgpio__DOT__mgpio__DOT__seg2), 8, SEG2A, SEG2B, SEG2C, SEG2D, SEG2E, SEG2F, SEG2G, DEC2P);
  nvboard_bind_pin(&CONCAT(VERILOG_PREFIX_PERIP, lgpio__DOT__mgpio__DOT__seg3), 8, SEG3A, SEG3B, SEG3C, SEG3D, SEG3E, SEG3F, SEG3G, DEC3P);
  nvboard_bind_pin(&CONCAT(VERILOG_PREFIX_PERIP, lgpio__DOT__mgpio__DOT__seg4), 8, SEG4A, SEG4B, SEG4C, SEG4D, SEG4E, SEG4F, SEG4G, DEC4P);
  nvboard_bind_pin(&CONCAT(VERILOG_PREFIX_PERIP, lgpio__DOT__mgpio__DOT__seg5), 8, SEG5A, SEG5B, SEG5C, SEG5D, SEG5E, SEG5F, SEG5G, DEC5P);
  nvboard_bind_pin(&CONCAT(VERILOG_PREFIX_PERIP, lgpio__DOT__mgpio__DOT__seg6), 8, SEG6A, SEG6B, SEG6C, SEG6D, SEG6E, SEG6F, SEG6G, DEC6P);
  nvboard_bind_pin(&CONCAT(VERILOG_PREFIX_PERIP, lgpio__DOT__mgpio__DOT__seg7), 8, SEG7A, SEG7B, SEG7C, SEG7D, SEG7E, SEG7F, SEG7G, DEC7P);

  nvboard_bind_pin(
      &top->rootp->ysyxSoCFull__DOT__asic__DOT__luart__DOT__muart__DOT__Uregs__DOT__serial_out,
      1, UART_TX);

  nvboard_bind_pin(
      &top->rootp->externalPins_uart_rx,
      1, UART_RX);

  nvboard_init();
#endif
}

void engine_start()
{
  sdb_mainloop();

  if (tfp)
  {
    tfp->dump(contextp->time());
    tfp->flush();
    tfp->close();
    delete tfp;
  }

  delete top;
  delete contextp;
}
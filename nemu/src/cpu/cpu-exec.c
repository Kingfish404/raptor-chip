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

#include <common.h>
#include <cpu/cpu.h>
#include <cpu/decode.h>
#include <cpu/difftest.h>
#include <isa.h>
#include <locale.h>
#include <unistd.h>
#include <fcntl.h>

/* The assembly code of instructions executed is only output to the screen
 * when the number of instructions executed is less than this value.
 * This is useful when you use the `si' command.
 * You can modify this value as you want.
 */
#define MAX_INST_TO_PRINT 10
#define MAX_IRING_SIZE 16

extern int boot_from_flash;
extern int ftracedepth_max;
FILE *pc_trace = NULL, *bpu_trace = NULL, *mem_trace = NULL;
size_t pc_continue_cnt = 1;

CPU_state cpu = {};
uint64_t g_nr_guest_inst = 0;
static uint64_t g_timer = 0; // unit: us
static bool g_print_step = false;
Decode iringbuf[MAX_IRING_SIZE];
uint64_t iringhead = 0;

#ifdef CONFIG_ITRACE
extern bool log_enable(void);
#endif

void device_update();

bool wp_check_changed();

uint64_t get_time();

static uint64_t nemu_start_timer = 0;

static void nemu_save_status_to_file(const char *filename)
{
  if (filename == NULL)
    return;
  if (nemu_start_timer == 0)
    nemu_start_timer = get_time();
  fflush(stdout);

  int saved_stdout = dup(fileno(stdout));
  int fd = open(filename, O_WRONLY | O_CREAT | O_TRUNC, 0644);
  if (fd < 0)
    return;
  dup2(fd, fileno(stdout));
  close(fd);

  uint64_t current_time = get_time();
  printf(" Simulated Time: %.3f s\n", (current_time - nemu_start_timer) / 1000000.0);
  printf("Simulated Speed: %.3f MIPS\n",
         (g_nr_guest_inst / 1000000.0) / ((current_time - nemu_start_timer) / 1000000.0));
  printf("\n");

  isa_reg_display();
  printf("\n");

  cpu_show_itrace();

  fflush(stdout);
  dup2(saved_stdout, fileno(stdout));
  close(saved_stdout);
}

static int nemu_save_uarch_state(const char *filename)
{
  if (filename == NULL)
    return -1;
  FILE *fp = fopen(filename, "w");
  if (fp == NULL)
    return -1;

  int gpr_num = MUXDEF(CONFIG_RVE, 16, 32);

  fprintf(fp, "{\n");
  fprintf(fp, "  \"pc\": \"" FMT_WORD "\",\n", cpu.pc);
  fprintf(fp, "  \"priv\": %d,\n", cpu.priv);
  fprintf(fp, "  \"inst_cnt\": %" PRIu64 ",\n", g_nr_guest_inst);
  fprintf(fp, "  \"gpr\": [\n");
  for (int i = 0; i < gpr_num; i++)
  {
    fprintf(fp, "    \"" FMT_WORD "\"%s\n", cpu.gpr[i], (i == gpr_num - 1) ? "" : ",");
  }
  fprintf(fp, "  ],\n");
  fprintf(fp, "  \"csr\": {\n");
  fprintf(fp, "    \"sstatus\": \"" FMT_WORD "\",\n", cpu.sr[CSR_SSTATUS]);
  fprintf(fp, "    \"sie\": \"" FMT_WORD "\",\n", cpu.sr[CSR_SIE]);
  fprintf(fp, "    \"stvec\": \"" FMT_WORD "\",\n", cpu.sr[CSR_STVEC]);
  fprintf(fp, "    \"sscratch\": \"" FMT_WORD "\",\n", cpu.sr[CSR_SSCRATCH]);
  fprintf(fp, "    \"sepc\": \"" FMT_WORD "\",\n", cpu.sr[CSR_SEPC]);
  fprintf(fp, "    \"scause\": \"" FMT_WORD "\",\n", cpu.sr[CSR_SCAUSE]);
  fprintf(fp, "    \"stval\": \"" FMT_WORD "\",\n", cpu.sr[CSR_STVAL]);
  fprintf(fp, "    \"sip\": \"" FMT_WORD "\",\n", cpu.sr[CSR_SIP]);
  fprintf(fp, "    \"satp\": \"" FMT_WORD "\",\n", cpu.sr[CSR_SATP]);
  fprintf(fp, "    \"mstatus\": \"" FMT_WORD "\",\n", cpu.sr[CSR_MSTATUS]);
  fprintf(fp, "    \"medeleg\": \"" FMT_WORD "\",\n", cpu.sr[CSR_MEDELEG]);
  fprintf(fp, "    \"mideleg\": \"" FMT_WORD "\",\n", cpu.sr[CSR_MIDELEG]);
  fprintf(fp, "    \"mie\": \"" FMT_WORD "\",\n", cpu.sr[CSR_MIE]);
  fprintf(fp, "    \"mtvec\": \"" FMT_WORD "\",\n", cpu.sr[CSR_MTVEC]);
  fprintf(fp, "    \"mscratch\": \"" FMT_WORD "\",\n", cpu.sr[CSR_MSCRATCH]);
  fprintf(fp, "    \"mepc\": \"" FMT_WORD "\",\n", cpu.sr[CSR_MEPC]);
  fprintf(fp, "    \"mcause\": \"" FMT_WORD "\",\n", cpu.sr[CSR_MCAUSE]);
  fprintf(fp, "    \"mtval\": \"" FMT_WORD "\",\n", cpu.sr[CSR_MTVAL]);
  fprintf(fp, "    \"mip\": \"" FMT_WORD "\"\n", cpu.sr[CSR_MIP]);
  fprintf(fp, "  }\n");
  fprintf(fp, "}");
  fclose(fp);
  return 0;
}

static void nemu_periodic_save(void)
{
  /* Dump status / uarch JSON every 100M guest instructions. The fopen +
   * multi-fprintf path was a top-5 host hotspot at the prior 1M cadence;
   * 100M reduces it to noise while still giving periodic checkpoints. */
  if ((g_nr_guest_inst % 100000000ULL) == 0)
  {
    const char *home = getenv("NEMU_HOME");
    if (!home)
      return;
    char path[512];
    snprintf(path, sizeof(path), "%s/../data/nemu-status.log", home);
    nemu_save_status_to_file(path);
    snprintf(path, sizeof(path), "%s/../data/nemu-uarch_state.json", home);
    nemu_save_uarch_state(path);
  }
}

#ifdef CONFIG_ITRACE
/* Format a single iringbuf entry into `out` on demand. Splitting the
 * snprintf+disassemble path out of `exec_once` avoids paying its (very
 * heavy: capstone + multiple snprintf) cost on every executed instruction
 * when its result would be discarded. We populate `s->logbuf` lazily, only
 * when one of these consumers will actually read it:
 *   1. log_enable()  — instruction trace file write window
 *   2. g_print_step  — short interactive `si N` runs
 *   3. cpu_show_itrace() on abort — formatted post-mortem
 */
static void itrace_format(Decode *s)
{
  /* Use s->epc (preserved executing PC) — s->pc has been clobbered to
   * s->dnpc by decode_exec, so `s->snpc - s->pc` would be wildly wrong
   * for taken branches and crash the snprintf/memset loop below. */
  vaddr_t epc = s->epc;
  char *p = s->logbuf;
  p += snprintf(p, sizeof(s->logbuf), FMT_WORD ":", epc);
  int ilen = (int)(s->snpc - epc);
  if (ilen <= 0 || ilen > 4)
  {
    ilen = 4; /* defensive: only RV inst lengths */
  }
  uint8_t *inst = (uint8_t *)&s->isa.inst;
  for (int i = ilen - 1; i >= 0; i--)
  {
    p += snprintf(p, 4, " %02x", inst[i]);
  }
  int ilen_max = 4;
  int space_len = ilen_max - ilen;
  if (space_len < 0)
  {
    space_len = 0;
  }
  space_len = space_len * 3 + 1;
  memset(p, ' ', space_len);
  p += space_len;
  void disassemble(char *str, int size, uint64_t pc, uint8_t *code, int nbyte);
  disassemble(p, s->logbuf + sizeof(s->logbuf) - p, epc, (uint8_t *)inst, ilen);
}
#endif

static void trace_and_difftest(Decode *_this, vaddr_t dnpc)
{
#ifdef CONFIG_ITRACE_COND
  /* Only format the disassembly when it will actually be consumed; this
   * skips ~50% of NEMU's per-instruction cost (capstone + snprintf) on
   * long benchmark runs where TRACE_END is reached early. */
  bool _itrace_need = log_enable() || g_print_step;
  if (_itrace_need)
  {
    itrace_format(_this);
  }
  if (ITRACE_COND && log_enable())
  {
    log_write("%s\n", _this->logbuf);
  }
#endif
  if (g_print_step)
  {
    IFDEF(CONFIG_ITRACE, puts(_this->logbuf));
  }
  IFDEF(CONFIG_DIFFTEST, difftest_step(_this->pc, dnpc));
#ifdef CONFIG_WATCHPOINT
  if (wp_check_changed())
  {
    set_nemu_state(NEMU_STOP, cpu.pc, -1);
    printf("wp changed at " FMT_WORD ", pc: " FMT_WORD "\n",
           (word_t)g_nr_guest_inst, cpu.pc);
  }
#endif
}

static void exec_once(Decode *s, vaddr_t pc)
{
  cpu.cpc = pc;
  s->pc = pc;
  s->snpc = pc;
  s->epc = pc; /* preserve executing PC for lazy itrace_format (s->pc gets
                * clobbered to dnpc by decode_exec) */
  isa_exec_once(s);
  if (boot_from_flash)
  {
    if (pc_trace == NULL)
    {
      pc_trace = fopen("./pc-trace.txt", "w");
      fprintf(pc_trace, FMT_WORD_NO_PREFIX "-", s->pc);
    }
    else
    {
      if (s->dnpc == s->snpc)
      {
        pc_continue_cnt++;
      }
      else
      {
        fprintf(pc_trace, "%zu\n", pc_continue_cnt);
        pc_continue_cnt = 1;
        fprintf(pc_trace, FMT_WORD_NO_PREFIX "-", s->pc);
      }
    }
    uint32_t opcode = BITS(s->isa.inst, 6, 0);
    {
      if (bpu_trace == NULL)
      {
        bpu_trace = fopen("./bpu-trace.txt", "w");
      }
      // branch: 0b1100011; jalr: 0b1100111 ; jal: 0b1101111 ;
      if (opcode == 0b1100011 || opcode == 0b1100111 || opcode == 0b1101111)
      {
        // jalr x0, 0(x1): 0x00008067, a.k.a. ret
        char btype = (s->isa.inst == 0x00008067) ? 'r' : (opcode == 0b1100011 ? 'b' : (opcode == 0b1100111 ? 'j' : 'c'));
        fprintf(bpu_trace, FMT_WORD_NO_PREFIX "-" FMT_WORD_NO_PREFIX "-%c\n",
                s->pc, s->dnpc, btype);
      };
    }
    {
      if (mem_trace == NULL)
      {
        mem_trace = fopen("./mem-trace.txt", "w");
      }
      // record vaddr of load and store at `vaddr.c`
    }
  }
#ifdef CONFIG_ITRACE
  /* Lazy iringbuf: just snapshot the Decode struct (cheap struct copy).
   * Heavy disassemble + snprintf is deferred to itrace_format(), called
   * only when output is actually needed (log_enable / print_step / abort). */
  iringbuf[iringhead] = *s;
  iringhead = (iringhead + 1) % MAX_IRING_SIZE;
  /* Mark the next-to-be-overwritten slot as "not yet formatted" so the
   * lazy formatter can detect it. The just-written entry keeps whatever
   * logbuf state it had (initially '\0'); cpu_show_itrace() reformats
   * from saved (pc, snpc, isa.inst) anyway. */
  iringbuf[iringhead].logbuf[0] = '\0';
#endif
  cpu.pc = s->pc;
  cpu.inst = s->isa.inst;
}

static void execute(uint64_t n)
{
  Decode s;
  for (; n > 0; n--)
  {
    word_t intr = isa_query_intr();
    if (intr != INTR_EMPTY)
    {
      // Log("nemu: intr %x at pc = " FMT_WORD, intr, cpu.pc);
      cpu.pc = isa_raise_intr(intr, cpu.pc);
      /* ref_difftest_raise_intr is only resolved when a --diff reference
       * .so is loaded; standalone runs (e.g. linux-boot-nemu32 without
       * difftest, RISCOF) leave it NULL and would segfault on the first
       * timer interrupt. Guard the call. */
      IFDEF(CONFIG_DIFFTEST, if (ref_difftest_raise_intr) ref_difftest_raise_intr(intr));
    }
    exec_once(&s, cpu.pc);

    g_nr_guest_inst++;
    nemu_periodic_save();
    trace_and_difftest(&s, cpu.pc);
    if (nemu_state.state != NEMU_RUNNING)
    {
      break;
    }
    IFDEF(CONFIG_DEVICE, device_update());
  }
}

void statistic()
{
  IFNDEF(CONFIG_TARGET_AM, setlocale(LC_NUMERIC, ""));
#define NUMBERIC_FMT MUXDEF(CONFIG_TARGET_AM, "%", "%'") PRIu64
  Log("ftracedepth_max = %d ", ftracedepth_max);
  Log("host time spent = " NUMBERIC_FMT " us", g_timer);
  Log("total guest instructions = " NUMBERIC_FMT, g_nr_guest_inst);
  if (g_timer > 0)
    Log("simulation frequency = " NUMBERIC_FMT " inst/s", g_nr_guest_inst * 1000000 / g_timer);
  else
    Log("Finish running in less than 1 us and can not calculate the simulation frequency");
}

void assert_fail_msg()
{
  isa_reg_display();
  cpu_show_itrace();
  statistic();
}

/* Simulate how the CPU works. */
void cpu_exec(uint64_t n)
{
  g_print_step = (n < MAX_INST_TO_PRINT);
  switch (nemu_state.state)
  {
  case NEMU_END:
  case NEMU_ABORT:
    printf("Program execution has ended. To restart the program, exit NEMU and run again.\n");
    return;
  default:
    nemu_state.state = NEMU_RUNNING;
  }

  uint64_t timer_start = get_time();

  execute(n);

  uint64_t timer_end = get_time();
  g_timer += timer_end - timer_start;

  switch (nemu_state.state)
  {
  case NEMU_RUNNING:
    nemu_state.state = NEMU_STOP;
    break;

  case NEMU_END:
  case NEMU_ABORT:
    if (nemu_state.state == NEMU_ABORT)
    {
      isa_reg_display();
      cpu_show_itrace();
    }
    Log("nemu: %s at pc = " FMT_WORD,
        (nemu_state.state == NEMU_ABORT ? ANSI_FMT("ABORT", ANSI_FG_RED) : (nemu_state.halt_ret == 0 ? ANSI_FMT("HIT GOOD TRAP", ANSI_FG_GREEN) : ANSI_FMT("HIT BAD TRAP", ANSI_FG_RED))),
        nemu_state.halt_pc);
    // fall through
  case NEMU_QUIT:
    statistic();
  }
}

void cpu_show_itrace()
{
#ifdef CONFIG_ITRACE
  for (size_t i = 0; i < MAX_IRING_SIZE; i++)
  {
    /* Skip empty slots: epc==0 means we never executed this slot
     * (initial zero-filled state) — real RV programs run from 0x1000+. */
    if (iringbuf[i].epc == 0)
    {
      continue;
    }
    /* Lazy disassembly: format the saved Decode now (post-mortem). */
    itrace_format(&iringbuf[i]);
    iringbuf[i].logbuf[0] = ' ';
    iringbuf[i].logbuf[1] = ' ';
    if ((i + 1) % MAX_IRING_SIZE == iringhead)
    {
      printf("-> %-76s\n", iringbuf[i].logbuf);
    }
    else
    {
      printf("   %-76s\n", iringbuf[i].logbuf);
    }
  }
#endif
}
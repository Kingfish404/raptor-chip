#include <am.h>
#include <riscv/riscv.h>
#include <klib.h>

static Context *(*user_handler)(Event, Context *) = NULL;
void __am_get_cur_as(Context *c);
void __am_switch(Context *c);

extern void __am_asm_trap(void);

Context *__am_irq_handle(Context *c)
{
  __am_get_cur_as(c);
  if (user_handler)
  {
    Event ev = {0};
    switch (c->mcause)
    {
    case 0x8ul: // Environment call from U-mode or VU-mode
    case 0x9ul: // Environment call from S-mode
    case 0xbul: // Environment call from M-mode
    {
      c->mepc += 4;
      if (c->GPR1 == -1)
      {
        ev.event = EVENT_YIELD;
      }
      else
      {
        ev.event = EVENT_SYSCALL;
      }
    }
    break;
#if defined(CONFIG_ISA64)
    case 0x8000000000000007:
#endif
    case 0x80000007:
    {
      ev.event = EVENT_IRQ_TIMER;
    }
    break;
    default:
    {
      ev.event = EVENT_ERROR;
    }
    break;
    }

    size_t mscratch = 0, sp;
    asm volatile("csrr %0, mscratch\nmv %1, sp" : "=r"(mscratch), "=r"(sp));
    // printf("- c: %p, c->np: %d, cp->gpr[sp]: %x, mscratch = %x, sp = %x\n",
    //        c, c->np, c->gpr[2], mscratch, sp);
    c = user_handler(ev, c);
    asm volatile("csrr %0, mscratch\nmv %1, sp" : "=r"(mscratch), "=r"(sp));
    // printf("= c: %p, c->np: %d, cp->gpr[sp]: %x, mscratch = %x, sp = %x\n",
    //        c, c->np, c->gpr[2], mscratch, sp);
    assert(c != NULL);
  }
  __am_switch(c);
  return c;
}

Context *kcontext(Area kstack, void (*entry)(void *), void *arg)
{
  Context *p = (Context *)(kstack.end - sizeof(Context));

  p->mepc = (uintptr_t)entry;
  p->gpr[r_a0] = (int)arg;

#ifdef CONFIG_ISA64
  p->mstatus = 0xa00001808;
#else // __risv32
  p->mstatus = 0x1808;
#endif
  p->np = PRV_M;
  return p;
}

void yield()
{
#ifdef __riscv_e
  asm volatile("li a5, -1; ecall");
#else
  asm volatile("li a7, -1; ecall");
#endif
}

bool ienabled()
{
  return false;
}

void iset(bool enable)
{
}

bool cte_init(Context *(*handler)(Event, Context *))
{
  // register event handler
  user_handler = handler;

  // initialize exception entry
  asm volatile("csrw mtvec, %0" : : "r"(__am_asm_trap));

#ifdef CONFIG_ISA64
  asm volatile("csrw mstatus, %0" : : "r"(0xa00001808));
#else // __risv32
  // MPP = 0b11, MIE = 0b1, enable interrupts
  asm volatile("csrw mstatus, %0" : : "r"(0x1808));
#endif

  return true;
}
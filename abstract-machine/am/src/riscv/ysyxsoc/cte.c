#include <am.h>
#include <riscv/riscv.h>
#include <klib.h>

static Context *(*user_handler)(Event, Context *) = NULL;

Context *__am_irq_handle(Context *c)
{
  if (user_handler)
  {
    Event ev = {0};
    switch (c->mcause)
    {
    case 0xbul:
    case 0x0ul:
      c->mepc += 4;
      ev.event = EVENT_YIELD;
      break;
    case 0x3ul:
      ev.event = EVENT_IRQ_TIMER;
      break;
    case 0x7ul:
      ev.event = EVENT_IRQ_IODEV;
      break;
    default:
      ev.event = EVENT_ERROR;
      break;
    }

    c = user_handler(ev, c);
    assert(c != NULL);
  }
  return c;
}

extern void __am_asm_trap(void);

bool cte_init(Context *(*handler)(Event, Context *))
{
  // initialize exception entry
  asm volatile("csrw mtvec, %0" : : "r"(__am_asm_trap));

#ifdef CONFIG_ISA64
  asm volatile("csrw mstatus, %0" : : "r"(0xa00001800));
#else // __risv32
  asm volatile("csrw mstatus, %0" : : "r"(0x1800));
#endif

  // register event handler
  user_handler = handler;

  return true;
}

Context *kcontext(Area kstack, void (*entry)(void *), void *arg)
{
  Context *p = (Context *)(kstack.end - sizeof(Context));

  p->mepc = (uintptr_t)entry;
  p->gpr[r_a0] = (int)arg;

#ifdef CONFIG_ISA64
  p->mstatus = 0xa00001800;
#else // __risv32
  p->mstatus = 0x1800;
#endif
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

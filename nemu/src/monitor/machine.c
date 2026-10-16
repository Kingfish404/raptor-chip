#include <isa.h>
#include <memory/paddr.h>
#include <cpu/thread.h>

void print_nemu_machine(void)
{
#ifdef CONFIG_ISA_riscv
  printf("{\"schema\":1,\"isa\":\"riscv\",\"xlen\":%u,\"max_harts\":%u,",
         MUXDEF(CONFIG_RV64, 64, 32), NEMU_MAX_HARTS);
  printf("\"memory\":{\"base\":%" PRIu64 ",\"size\":%" PRIu64 "},",
         (uint64_t)CONFIG_MBASE, (uint64_t)CONFIG_MSIZE);
  printf("\"rom\":{\"base\":%" PRIu64 ",\"dtb_max_size\":%u},",
         CONFIG_ROM_BASE, CONFIG_ROM_SIZE - 33);
  printf("\"vm_boot\":%s,\"threaded\":%s,\"cycle_timer\":%s,",
         ISDEF(CONFIG_TARGET_NATIVE_ELF) && ISDEF(CONFIG_ROM) && ISDEF(CONFIG_ROM_DTB) &&
         ISDEF(CONFIG_RV_F) && ISDEF(CONFIG_RV_D) && !ISDEF(CONFIG_RVE) &&
         CONFIG_MBASE == 0x80000000 && CONFIG_PC_RESET_OFFSET == 0 ? "true" : "false",
         ISDEF(NEMU_HAS_THREADS) ? "true" : "false", ISDEF(CONFIG_TIMER_CYCLE) ? "true" : "false");
  printf("\"profiles\":[\"none\"");
#if defined(CONFIG_RV64) && defined(CONFIG_MODE_SYSTEM) && defined(CONFIG_RV_F) && \
    defined(CONFIG_RV_D) && defined(CONFIG_RV_SVADE) && defined(CONFIG_TIMER_CYCLE) && !defined(CONFIG_RVE)
  printf(",\"rva23\"");
#endif
  printf("],\"devices\":{\"timebase_hz\":10000000");
#ifdef CONFIG_HAS_SERIAL
  printf(",\"uart\":{\"base\":%u,\"size\":256,\"irq\":%u}",
         CONFIG_SERIAL_MMIO_US16550, CONFIG_SERIAL_PLIC_IRQ);
#endif
#ifdef CONFIG_HAS_TIMER
  printf(",\"clint\":{\"base\":%u,\"size\":786432}", CONFIG_RTC_MMIO_CLINT);
#endif
#ifdef CONFIG_DEVICE
  printf(",\"plic\":{\"base\":%u,\"size\":16777216,\"sources\":32}", CONFIG_PLIC_MMIO);
#endif
#ifdef CONFIG_HAS_FINISHER
  printf(",\"finisher\":{\"base\":%u,\"size\":4096}", CONFIG_FINISHER_MMIO);
#endif
#ifdef CONFIG_HAS_DISK
  printf(",\"block\":{\"base\":268439552,\"size\":4096,\"irq\":1}");
#endif
#ifdef CONFIG_HAS_NET
  printf(",\"net\":{\"base\":%u,\"size\":4096,\"irq\":%u,\"hostfwd_max\":16}", CONFIG_NET_MMIO, CONFIG_NET_PLIC_IRQ);
#endif
#ifdef CONFIG_HAS_RNG
  printf(",\"rng\":{\"base\":%u,\"size\":4096,\"irq\":%u}", CONFIG_RNG_MMIO, CONFIG_RNG_PLIC_IRQ);
#endif
  puts("}}");
#else
  puts("{\"schema\":1,\"isa\":\"x86\",\"vm_boot\":false}");
#endif
}

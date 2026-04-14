/***************************************************************************************
 * QEMU virt / SiFive Test finisher device for NEMU
 *
 * Compatible with "sifive,test1" / "syscon-poweroff" / "syscon-reboot".
 * Write 0x5555 to base+0x0 => poweroff (PASS)
 * Write 0x3333 to base+0x0 => fail
 * Write 0x7777 to base+0x0 => reset/reboot
 ***************************************************************************************/

#include <utils.h>
#include <device/map.h>
#include <cpu/cpu.h>

#define FINISHER_PASS  0x5555
#define FINISHER_FAIL  0x3333
#define FINISHER_RESET 0x7777

static uint8_t *finisher_base = NULL;

static void finisher_io_handler(uint32_t offset, int len, bool is_write) {
  if (is_write && offset == 0) {
    uint32_t val = *(uint32_t *)finisher_base;
    uint16_t cmd = val & 0xffff;
    if (cmd == FINISHER_PASS) {
      uint16_t exit_code = (val >> 16) & 0xffff;
      Log("Finisher: poweroff (val=0x%x, exit_code=%d)", val, exit_code);
      set_nemu_state(NEMU_END, 0, exit_code);
    } else if (cmd == FINISHER_FAIL) {
      Log("Finisher: fail (val=0x%x)", val);
      set_nemu_state(NEMU_ABORT, 0, 1);
    } else if (cmd == FINISHER_RESET) {
      Log("Finisher: reset requested (val=0x%x) — not supported, aborting", val);
      set_nemu_state(NEMU_ABORT, 0, 1);
    }
  }
}

void init_finisher() {
  finisher_base = new_space(0x1000);
  add_mmio_map("finisher", CONFIG_FINISHER_MMIO, finisher_base, 0x1000,
               finisher_io_handler);
}

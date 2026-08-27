/* QEMU fw-cfg compatibility device.
 *
 * NetBSD probes this optional device from the QEMU virt device tree. NEMU
 * does not expose fw-cfg data, but the MMIO region must still be present so
 * the probe receives harmless zero values instead of a machine trap.
 */

#include <device/map.h>

#define FWCFG_MMIO_BASE 0x10100000u
#define FWCFG_MMIO_SIZE 0x18u

void init_fwcfg(void)
{
  uint8_t *fwcfg_space = new_space(FWCFG_MMIO_SIZE);
  memset(fwcfg_space, 0, FWCFG_MMIO_SIZE);
  add_mmio_map("fw-cfg", FWCFG_MMIO_BASE, fwcfg_space, FWCFG_MMIO_SIZE, NULL);
}
#ifndef RAPT_BOOT_H
#define RAPT_BOOT_H

/* Physical 32-bit MMIO; requested bits apply at the next drained core reset. */
#define RAPT_BOOT_CONTROL 0x00100808
#define RAPT_BOOT_FLASH 0x1
#define RAPT_BOOT_ROM_XIP 0x2
#define RAPT_BOOT_DEFAULT 0x3
#define RAPT_BOOT_ACTIVE_SHIFT 16

#endif

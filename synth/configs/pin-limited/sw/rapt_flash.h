/* DirectFlash ABI v1. Registers require aligned 32-bit, single-beat accesses.
 * A failed command raises an AXI error (CPU access fault / JTAG SBA error).
 * Handle that fault before reading STATUS; never automatically retry mutation.
 */
#ifndef RAPT_CHIP_FLASH_H
#define RAPT_CHIP_FLASH_H

#define RAPT_FLASH_CTRL_BASE 0x00100800
#define RAPT_FLASH_HALF_PERIOD 0x00
#define RAPT_FLASH_SRAM_CTRL 0x04
#define RAPT_FLASH_STATUS 0x10
#define RAPT_FLASH_JEDEC_ID 0x14
#define RAPT_FLASH_OFFSET 0x18
#define RAPT_FLASH_DATA 0x1c
#define RAPT_FLASH_COMMAND 0x20
#define RAPT_FLASH_CAP 0x24
#define RAPT_FLASH_CAPACITY 0x28
#define RAPT_FLASH_ERASE_SIZE 0x2c
/* Read-only physical mapping/protection; WRITE_END is exclusive. */
#define RAPT_FLASH_STORAGE_OFFSET 0x30
#define RAPT_FLASH_WRITE_START 0x34
#define RAPT_FLASH_WRITE_END 0x38

#define RAPT_FLASH_CMD_PROGRAM32 0x52460001
#define RAPT_FLASH_CMD_ERASE4K 0x52460002
#define RAPT_FLASH_CMD_RECOVER 0x52460003
#define RAPT_FLASH_CMD_IDENTIFY 0x52460004
#define RAPT_FLASH_CMD_STATUS 0x52460005
#define RAPT_FLASH_READY 0x01
#define RAPT_FLASH_BUSY 0x02
#define RAPT_FLASH_RECOVERY_REQUIRED 0x04
#define RAPT_FLASH_OCTAL_ACTIVE 0x08
#define RAPT_FLASH_ERROR_SHIFT 8
#define RAPT_FLASH_SR1_SHIFT 16
#define RAPT_FLASH_SR2_SHIFT 24

#define RAPT_FLASH_ERR_TIMEOUT 1
#define RAPT_FLASH_ERR_IDENTITY 2
#define RAPT_FLASH_ERR_STATE 3
#define RAPT_FLASH_ERR_WEL 4
#define RAPT_FLASH_ERR_VERIFY 5
#define RAPT_FLASH_ERR_ADDRESS 6
#define RAPT_FLASH_ERR_SFDP 7

/* W25Q64JW-IQ is a 1.7-1.95 V part; ID does not measure board voltage. */
#define RAPT_FLASH_EXPECTED_ID 0x00ef6017
#define RAPT_FLASH_OCTAL_ID 0x002c5b19
#define RAPT_FLASH_REQUIRED_IO_MV 1800

#define RAPT_FLASH_XIP_BASE 0x30000000
#define RAPT_FLASH_BOOT_BASE 0x20000000
#define RAPT_FLASH_BYTES 0x00800000
#define RAPT_FLASH_RAM_BASE 0x0f000000
#define RAPT_FLASH_RAM_BYTES 0x00002000

#ifndef __ASSEMBLER__
#include <stdint.h>

static inline volatile uint32_t *rapt_flash_reg(uint32_t offset) {
    return (volatile uint32_t *)(uintptr_t)(RAPT_FLASH_CTRL_BASE + offset);
}
#endif
#endif

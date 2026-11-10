/* CPU integration proof: reset-vector XIP, initialized data, BSS, stack, SRAM
 * execution, explicit sector erase/program, readback and ordinary-store fault.
 */
#include "rapt_flash.h"
.option norvc
.option norelax
.section .text.start
.globl _start
_start:
  la sp, _stack_top
  la t0, boot_fail
  csrw mtvec, t0
  csrw mie, zero
  csrw mstatus, zero
  la t0, _sram_load
  la t1, _sram_start
  la t2, _sram_end
1:
  beq t1, t2, 2f
  lw t3, 0(t0)
  sw t3, 0(t1)
  addi t0, t0, 4
  addi t1, t1, 4
  j 1b
2:
  la t0, _bss_start
  la t1, _bss_end
3:
  beq t0, t1, 4f
  sw zero, 0(t0)
  addi t0, t0, 4
  j 3b
4:
  fence iorw,iorw
  fence.i
  la t0, trap
  csrw mtvec, t0
  li s0, 0
  la t0, run_from_ram
  jr t0

boot_fail:
  li t0, RAPT_FLASH_CTRL_BASE
  li t1, 0x0badcafe
  sw t1, RAPT_FLASH_DATA(t0)
  fence iorw,iorw
  ebreak
  j boot_fail

.section .ramtext,"ax"
.balign 4
trap:
  csrr t0, mcause
  li t1, 7
  bne t0, t1, fail
  beqz s0, fail
  li s0, 0
  csrr t0, mepc
  addi t0, t0, 4
  csrw mepc, t0
  mret
fail:
  li t0, RAPT_FLASH_CTRL_BASE
  li t1, 0x0badcafe
  sw t1, RAPT_FLASH_DATA(t0)
  fence iorw,iorw
  ebreak
  j fail

.balign 4
run_from_ram:
  addi sp, sp, -16
  li t0, 0x13579bdf
  sw t0, 0(sp)
  fence rw,rw
  lw t1, 0(sp)
  bne t0, t1, fail
  la t2, initialized_data
  lw t1, 0(t2)
  bne t0, t1, fail
  la t2, zero_data
  lw t1, 0(t2)
  bnez t1, fail
  li t0, RAPT_FLASH_CTRL_BASE
  lw t1, RAPT_FLASH_JEDEC_ID(t0)
  li t2, RAPT_FLASH_EXPECTED_ID
  beq t1, t2, 6f
  li t2, RAPT_FLASH_OCTAL_ID
  bne t1, t2, fail
6:
  lw t1, RAPT_FLASH_STATUS(t0)
  andi t1, t1, 7
  li t2, 1
  bne t1, t2, fail
  li t1, 0x10000
  sw t1, RAPT_FLASH_OFFSET(t0)
  li t1, RAPT_FLASH_CMD_ERASE4K
  sw t1, RAPT_FLASH_COMMAND(t0)
  fence iorw,iorw
  li t1, 0x1234abcd
  sw t1, RAPT_FLASH_DATA(t0)
  li t1, RAPT_FLASH_CMD_PROGRAM32
  sw t1, RAPT_FLASH_COMMAND(t0)
  fence iorw,iorw
  lw t1, RAPT_FLASH_STATUS(t0)
  srli t1, t1, RAPT_FLASH_ERROR_SHIFT
  andi t1, t1, 255
  bnez t1, fail
  li t1, RAPT_FLASH_XIP_BASE + 0x10000
  lw t2, 0(t1)
  li t3, 0x1234abcd
  bne t2, t3, fail
  // PMA must reject an ordinary store to read-only Flash.
  li s0, 1
  sw zero, 0(t1)
  fence iorw,iorw
  bnez s0, fail
  li t0, RAPT_FLASH_CTRL_BASE
  li t1, 0x600dcafe
  sw t1, RAPT_FLASH_DATA(t0)
  fence iorw,iorw
  ebreak
5:
  j 5b

.section .data
.balign 4
initialized_data:
  .word 0x13579bdf
.section .bss
.balign 4
zero_data:
  .zero 4

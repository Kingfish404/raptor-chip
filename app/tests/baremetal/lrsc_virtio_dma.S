/* Real NPC virtio read: device overwrites the byte covered by LR.W.
 * No difftest reference is needed to detect the forbidden successful SC.
 * Run with a private nonempty --disk image. */
.option norvc
.option norelax
.section .text
.globl _start
_start:
  la t0, trap_fail
  csrw mtvec, t0
  csrw mie, zero
  csrw mstatus, zero
  li s0, 0x10001000
  lw t0, 8(s0)
  li t1, 2
  bne t0, t1, device_fail
  sw zero, 0x70(s0)
  sw zero, 0x30(s0)
  li t0, 8
  sw t0, 0x38(s0)
  la t0, descriptors
  sw t0, 0x80(s0)
  sw zero, 0x84(s0)
  la t0, available
  sw t0, 0x90(s0)
  sw zero, 0x94(s0)
  la t0, used
  sw t0, 0xa0(s0)
  sw zero, 0xa4(s0)
  li t0, 1
  sw t0, 0x44(s0)
  li t0, 4
  sw t0, 0x70(s0)
  fence iorw, iorw
#ifdef DMA_PROGRESS_ONLY
  /* A 4096-byte IN request on the runner's 512-byte disk produces a finite
   * burst of zero-tail notifications. The LR/SC word is outside that range.
   * No post-notify FENCE drains the burst on behalf of the constrained loop. */
  sw zero, 0x50(s0)
  la s1, progress_word
  li s4, 32
  li s5, 0
progress_again:
  la t0, progress_loop
  jalr ra, t0, 0
  addi s5, s5, 1
  lw t0, 0(s1)
  bne t0, s5, reservation_fail
  addi s4, s4, -1
  bnez s4, progress_again
  lw t0, 0x60(s0)
  andi t0, t0, 1
  beqz t0, device_fail
  la t0, dma_status
  cbo.inval (t0)
  fence iorw, iorw
  lbu t1, 0(t0)
  bnez t1, dma_fail
  la t0, buffer
  lw t1, 0(t0)
  li t2, 0x03020100
  bne t1, t2, dma_fail
  lbu t1, 512(t0)
  bnez t1, dma_fail
  li t1, 4095
  add t0, t0, t1
  lbu t1, 0(t0)
  bnez t1, dma_fail
  li a0, 0
  ebreak
#else
  la s1, dma_status
  lr.w s2, (s1)
  li t0, 255
  bne s2, t0, initial_fail
  sw zero, 0x50(s0)
  fence iorw, iorw
  /* Confirm the actual device transaction and overlapping byte write. */
  lw t0, 0x60(s0)
  andi t0, t0, 1
  beqz t0, device_fail
  /* NPC DMA is non-snooping: invalidate the CPU cache before observation. */
  cbo.inval (s1)
  fence iorw, iorw
  lbu t0, 0(s1)
  bnez t0, dma_fail
  li t2, 0x55
.globl sc_probe
sc_probe:
#ifndef DMA_CONTROL_ONLY
  sc.w s3, t2, (s1)
  beqz s3, reservation_fail
#endif
  lbu t0, 0(s1)
  bnez t0, dma_fail
  li a0, 0
  ebreak
#endif
reservation_fail:
  li a0, 1
  j finish
initial_fail:
  li a0, 2
  j finish
device_fail:
  li a0, 3
  j finish
dma_fail:
  li a0, 4
  j finish
trap_fail:
  li a0, 5
finish:
  ebreak
  j finish
#ifdef DMA_PROGRESS_ONLY
.balign 64
.globl progress_loop
progress_loop:
  lr.w.aq t0, (s1)
  addi t0, t0, 1
  .rept 12
  addi zero, zero, 0
  .endr
  sc.w.rl t1, t0, (s1)
  bnez t1, progress_loop
.globl progress_loop_end
progress_loop_end:
  ret
#endif
.section .data
.balign 64
descriptors:
  .dword request
  .word 16
  .half 1, 1
  .dword buffer
#ifdef DMA_PROGRESS_ONLY
  .word 4096
#else
  .word 512
#endif
  .half 3, 2
  .dword dma_status
  .word 1
  .half 2, 0
  .zero 80
.balign 64
available:
  .half 0, 1, 0
  .zero 26
.balign 64
used: .zero 80
.balign 64
request:
  .word 0, 0
  .dword 0
.balign 64
dma_status: .word 255
  .zero 60
.balign 64
buffer:
#ifdef DMA_PROGRESS_ONLY
  .fill 4096, 1, 0xa5
.balign 64
progress_word: .word 0
#else
  .zero 512
#endif

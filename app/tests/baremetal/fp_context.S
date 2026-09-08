/* Two U-mode FP contexts, S-mode eager save and lazy restore on FS=Off.
 * Every FPR carries a distinct raw 64-bit payload (including NaNs), and
 * every round modifies all 32 signs and FCSR. Eight rounds are checked
 * against separate integer-maintained expected images. Each restore also
 * injects a delegated SSIP before the task resumes. Both XLENs, Bare.
 */
.option norvc
.option norelax
.macro save_fp base
  .set offset, 0
  .irp f,0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
    fsd f\f, offset(\base)
    .set offset, offset+8
  .endr
.endm
.macro load_fp base
  .set offset, 0
  .irp f,0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
    fld f\f, offset(\base)
    .set offset, offset+8
  .endr
.endm
.section .text
.globl _start
_start:
  la t0, fail
  csrw mtvec, t0
  csrw mie, zero
  csrw satp, zero
  li t0, -1
  csrw pmpaddr0, t0
  li t0, 0x1f
  csrw pmpcfg0, t0
  li t0, 0x104 /* U ECALL and illegal instruction delegated to S. */
  csrw medeleg, t0
  li t0, 2
  csrw mideleg, t0
  csrw mie, t0
  la t0, supervisor_trap
  csrw stvec, t0
  csrw mstatus, zero
  li s0, 0 /* current task */
  li s3, 0 /* completed rounds */
  li s4, 0 /* lazy restores */
  li s5, 0 /* interrupts between restore and first user FP access */
  la t0, user_body
  csrw mepc, t0
  mret
user_body:
  la s1, expected0
  beqz s0, 1f
  la s1, expected1
1: la s2, observed
probe:
  save_fp s2
  csrr t0, fcsr
  sw t0, 256(s2)
  /* Integer reference comparison includes both halves of every FPR. */
  li t0, 65
  mv t1, s1
  mv t2, s2
1: lw t3, 0(t1)
  lw t4, 0(t2)
  bne t3, t4, fail
  addi t1, t1, 4
  addi t2, t2, 4
  addi t0, t0, -1
  bnez t0, 1b
  .irp f,0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
    fsgnjn.d f\f, f\f, f\f
  .endr
  /* Update the independent expected image with integer sign-bit XOR. */
  li t0, 32
  addi t1, s1, 4
  li t2, 0x80000000
1: lw t3, 0(t1)
  xor t3, t3, t2
  sw t3, 0(t1)
  addi t1, t1, 8
  addi t0, t0, -1
  bnez t0, 1b
  addi t0, s0, 1
  slli t0, t0, 5
  addi t1, s3, 1
  or t0, t0, t1
  csrw fcsr, t0
  sw t0, 256(s1)
  ecall
  j fail
.balign 4
supervisor_trap:
  csrr t0, scause
  bltz t0, software_interrupt
  li t1, 2
  beq t0, t1, lazy_restore
  li t1, 8
  bne t0, t1, fail
  csrr t0, sstatus
  bgez t0, fail
  li t1, 0x6000
  and t0, t0, t1
  bne t0, t1, fail
  la t5, context0
  beqz s0, 1f
  la t5, context1
1: save_fp t5
  csrr t0, fcsr
  sw t0, 256(t5)
  /* Verify saved state before handing the physical register file away. */
  mv t1, s1
  mv t2, t5
  li t0, 65
1: lw t3, 0(t1)
  lw t4, 0(t2)
  bne t3, t4, fail
  addi t1, t1, 4
  addi t2, t2, 4
  addi t0, t0, -1
  bnez t0, 1b
  addi s3, s3, 1
  li t0, 8
  beq s3, t0, finish
  xori s0, s0, 1
  li t0, 0x6000
  csrc sstatus, t0
  la t0, user_body
  csrw sepc, t0
  sret
lazy_restore:
  csrr t0, sstatus
  li t1, 0x6000
  and t0, t0, t1
  bnez t0, fail
  csrr t0, sepc
  la t1, probe
  bne t0, t1, fail
  csrr t1, stval
#if __riscv_xlen == 64
  lwu t2, 0(t0)
#else
  lw t2, 0(t0)
#endif
  bne t1, t2, fail
  li t0, 0x2000
  csrs sstatus, t0
  la t5, context0
  beqz s0, 1f
  la t5, context1
1: load_fp t5
  lw t0, 256(t5)
  csrw fcsr, t0
  li t0, 0x6000
  csrc sstatus, t0
  li t0, 0x4000
  csrs sstatus, t0
  addi s4, s4, 1
  csrsi sip, 2
  sret
software_interrupt:
  /* Check the interrupt code independently of XLEN. SIE is clear inside
   * the handler; the pending interrupt is taken on return to U-mode. */
  slli t0, t0, 1
  li t1, 2
  bne t0, t1, fail
  csrci sip, 2
  addi s5, s5, 1
  sret
finish:
  li t0, 8
  bne s4, t0, fail
  bne s5, t0, fail
pass:
  li a0, 0
  ebreak
fail:
  li a0, 1
  ebreak
  j fail
.section .data

.balign 8
context0:
  .dword 0x0000000000000000
  .dword 0x8000000000000000
  .dword 0x7ff0000000000000
  .dword 0xfff0000000000000
  .dword 0x7ff0000000000001
  .dword 0x7ff8123456789abc
  .dword 0x3ff00006d3a06d36
  .dword 0x3ff00007f6e5d4bf
  .dword 0x3ff000091a2b3c48
  .dword 0x3ff0000a3d70a3d1
  .dword 0x3ff0000b60b60b5a
  .dword 0x3ff0000c83fb72e3
  .dword 0x3ff0000da740da6c
  .dword 0x3ff0000eca8641f5
  .dword 0x3ff0000fedcba97e
  .dword 0x3ff0001111111107
  .dword 0x3ff0001234567890
  .dword 0x3ff00013579be019
  .dword 0x3ff000147ae147a2
  .dword 0x3ff000159e26af2b
  .dword 0x3ff00016c16c16b4
  .dword 0x3ff00017e4b17e3d
  .dword 0x3ff0001907f6e5c6
  .dword 0x3ff0001a2b3c4d4f
  .dword 0x3ff0001b4e81b4d8
  .dword 0x3ff0001c71c71c61
  .dword 0x3ff0001d950c83ea
  .dword 0x3ff0001eb851eb73
  .dword 0x3ff0001fdb9752fc
  .dword 0x3ff00020fedcba85
  .dword 0x3ff000222222220e
  .dword 0x3ff0002345678997
  .word 33
  .word 0

.balign 8
context1:
  .dword 0x8000000000010001
  .dword 0x0000000000020002
  .dword 0xfff0000000030003
  .dword 0x7ff0000000040004
  .dword 0xfff0000000050004
  .dword 0xfff81234567e9aba
  .dword 0xbff00006d3a76d31
  .dword 0xbff00007f6edd4b7
  .dword 0xbff000091a223c41
  .dword 0xbff0000a3d7aa3db
  .dword 0xbff0000b60bd0b51
  .dword 0xbff0000c83f772ef
  .dword 0xbff0000da74dda61
  .dword 0xbff0000eca8841fb
  .dword 0xbff0000fedc4a971
  .dword 0xbff0001111011117
  .dword 0xbff0001234477881
  .dword 0xbff000135789e00b
  .dword 0xbff000147af247b1
  .dword 0xbff000159e32af3f
  .dword 0xbff00016c17916a1
  .dword 0xbff00017e4a77e2b
  .dword 0xbff0001907e1e5d1
  .dword 0xbff0001a2b244d57
  .dword 0xbff0001b4e98b4c1
  .dword 0xbff0001c71dd1c7b
  .dword 0xbff0001d951783f1
  .dword 0xbff0001eb84deb6f
  .dword 0xbff0001fdb8a52e1
  .dword 0xbff00020fec2ba9b
  .dword 0xbff00022223d2211
  .dword 0xbff00023454789b7
  .word 67
  .word 0

.balign 8
expected0:
  .dword 0x0000000000000000
  .dword 0x8000000000000000
  .dword 0x7ff0000000000000
  .dword 0xfff0000000000000
  .dword 0x7ff0000000000001
  .dword 0x7ff8123456789abc
  .dword 0x3ff00006d3a06d36
  .dword 0x3ff00007f6e5d4bf
  .dword 0x3ff000091a2b3c48
  .dword 0x3ff0000a3d70a3d1
  .dword 0x3ff0000b60b60b5a
  .dword 0x3ff0000c83fb72e3
  .dword 0x3ff0000da740da6c
  .dword 0x3ff0000eca8641f5
  .dword 0x3ff0000fedcba97e
  .dword 0x3ff0001111111107
  .dword 0x3ff0001234567890
  .dword 0x3ff00013579be019
  .dword 0x3ff000147ae147a2
  .dword 0x3ff000159e26af2b
  .dword 0x3ff00016c16c16b4
  .dword 0x3ff00017e4b17e3d
  .dword 0x3ff0001907f6e5c6
  .dword 0x3ff0001a2b3c4d4f
  .dword 0x3ff0001b4e81b4d8
  .dword 0x3ff0001c71c71c61
  .dword 0x3ff0001d950c83ea
  .dword 0x3ff0001eb851eb73
  .dword 0x3ff0001fdb9752fc
  .dword 0x3ff00020fedcba85
  .dword 0x3ff000222222220e
  .dword 0x3ff0002345678997
  .word 33
  .word 0

.balign 8
expected1:
  .dword 0x8000000000010001
  .dword 0x0000000000020002
  .dword 0xfff0000000030003
  .dword 0x7ff0000000040004
  .dword 0xfff0000000050004
  .dword 0xfff81234567e9aba
  .dword 0xbff00006d3a76d31
  .dword 0xbff00007f6edd4b7
  .dword 0xbff000091a223c41
  .dword 0xbff0000a3d7aa3db
  .dword 0xbff0000b60bd0b51
  .dword 0xbff0000c83f772ef
  .dword 0xbff0000da74dda61
  .dword 0xbff0000eca8841fb
  .dword 0xbff0000fedc4a971
  .dword 0xbff0001111011117
  .dword 0xbff0001234477881
  .dword 0xbff000135789e00b
  .dword 0xbff000147af247b1
  .dword 0xbff000159e32af3f
  .dword 0xbff00016c17916a1
  .dword 0xbff00017e4a77e2b
  .dword 0xbff0001907e1e5d1
  .dword 0xbff0001a2b244d57
  .dword 0xbff0001b4e98b4c1
  .dword 0xbff0001c71dd1c7b
  .dword 0xbff0001d951783f1
  .dword 0xbff0001eb84deb6f
  .dword 0xbff0001fdb8a52e1
  .dword 0xbff00020fec2ba9b
  .dword 0xbff00022223d2211
  .dword 0xbff00023454789b7
  .word 67
  .word 0

.balign 8
observed:
  .zero 264

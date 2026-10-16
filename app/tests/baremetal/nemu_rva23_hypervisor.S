.option norvc
.option norelax
.section .text
.globl _start
_start:
  li s11, 1
  la t0, fail
  csrw mtvec, t0
  csrr t0, misa
  li t1, (1 << 21) | (1 << 7)
  and t0, t0, t1
  bne t0, t1, fail
  li t0, -1
  csrw pmpaddr0, t0
  li t0, 15
  csrw pmpcfg0, t0
  li t0, -1
  csrw 0x30c, t0
  csrw 0x30d, t0
  csrw 0x30e, t0
  csrw 0x30f, t0
  csrw 0x60c, t0
  csrw 0x60d, t0
  csrw 0x60e, t0
  csrw 0x60f, t0
  li t0, 7
  csrw mcounteren, t0
  csrw 0x606, t0
  csrw scounteren, t0
  li t0, 1 << 63
  csrw 0x30a, t0
  csrw 0x60a, t0
  li t0, -1
  csrw 0x24d, t0
  li t0, 0x10000
  csrw 0x605, t0
  li t0, (1 << 2) | (1 << 10) | (1 << 13) | (1 << 21) | (1 << 22)
  csrw medeleg, t0
  li t0, (1 << 2) | (1 << 13)
  csrw 0x602, t0
  li t0, 0x44
  csrw 0x603, t0
  la t0, hs_trap
  csrw stvec, t0
  la t0, vs_trap
  csrw 0x205, t0
  li s0, 0
  li s1, 0
  li s2, 0
  li s9, 0
  li s10, 0
  la t0, hs_entry
  csrw mepc, t0
  li t0, 0x6e00
  csrw mstatus, t0
  mret

hs_entry:
  li s11, 2
  csrw 0x10c, zero
  csrw 0x10d, zero
  csrw 0x10e, zero
  csrw 0x10f, zero
  csrr t0, 0x606
  li t1, 7
  bne t0, t1, fail
  la t0, g_root
  li t1, 0x200000df
  sd t1, 16(t0)
  srli t0, t0, 12
  li t1, 8 << 60
  or t0, t0, t1
  csrw 0x680, t0
  csrr t2, 0x680
  bne t0, t2, fail
  la t0, vs_root
  li t1, 0x200000cf
  sd t1, 16(t0)
  li t1, 0x100000cf
  sd t1, 8(t0)
  srli t0, t0, 12
  li t1, 8 << 60
  or t0, t0, t1
  csrw 0x280, t0
  csrr t2, 0x280
  bne t0, t2, fail
  .word 0x62000073
  .word 0x22000073

  li s11, 3
  li t0, 0x100
  csrw 0x600, t0
  la a0, guest_data
  li a1, 0x12345678
  .word 0x6ab54073
  .word 0x68054673
  bne a1, a2, fail
  li s8, 21
  li s7, 0x40000000
  li s6, 0x10000000
  li s5, 0x40
  mv a0, s7
  .word 0x68054673
  li t0, 1
  bne s0, t0, fail

  li s11, 4
  li t0, 0x6202
  csrw 0x200, t0
  li t0, 0x22
  csrw 0x204, t0
  li t0, 4
  csrw 0x645, t0
  li t0, 0x180
  csrw 0x600, t0
  li t0, 0x100
  csrs sstatus, t0
  la t0, vs_entry
  csrw sepc, t0
  sret

vs_entry:
  li s11, 5
#ifdef FAIL_GUEST
  j guest_fail
#endif
  li t0, 1
  bne s2, t0, guest_fail
  li s3, 2
  li s4, 0x7b
  .word 0x0000007b
  li s11, 6
  li s3, 13
  li s4, 0x1000
  ld t0, 0(s4)
  li t0, 2
  bne s1, t0, guest_fail

  li s11, 7
  li s8, 21
  li s7, 0x40000000
  li s6, 0x10000000
  li s5, 0xc0
  ld t0, 0(s7)

  li s11, 8
  li s8, 22
  li s7, 0x600022f3
  li s6, 0
  li s5, 0x80
  .word 0x600022f3

  li s11, 9
  li s8, 10
  li s7, 0
  ecall
  li t0, 4
  bne s0, t0, guest_fail

  li s11, 10
  csrr t0, time
  li t1, 0x10000
  bltu t0, t1, guest_fail
  addi t0, t0, 64
  csrw 0x14d, t0
  li t0, 1000000
wait_guest_timer:
  bnez s9, guest_timer_done
  addi t0, t0, -1
  bnez t0, wait_guest_timer
  j guest_fail
guest_timer_done:
  li t0, 1
  bne s9, t0, guest_fail
  li s11, 11
  li t0, 4
  .word (0xd0 << 20) | (5 << 15) | (7 << 12) | (6 << 7) | 0x57
  li t2, 4
  bne t1, t2, guest_fail
  li t0, 17
  .word (0x17 << 26) | (1 << 25) | (5 << 15) | (4 << 12) | (8 << 7) | 0x57
  la t0, guest_vector
  .word (1 << 25) | (5 << 15) | (6 << 12) | (8 << 7) | 0x27
  lw t1, 0(t0)
  li t2, 17
  bne t1, t2, guest_fail
  lw t1, 12(t0)
  bne t1, t2, guest_fail
  li s10, 1
  ecall

hs_done:
  li s11, 12
  li t0, 5
  bne s0, t0, fail
  csrr t0, 0x600
  andi t0, t0, 0x80
  bnez t0, fail
  csrr t0, 0x200
  li t1, 0x600
  and t0, t0, t1
  bne t0, t1, fail
  li a0, 0
  j finish

.balign 4
hs_trap:
  bltz s10, fail
  csrr t0, scause
  bne t0, s8, fail
  csrr t0, stval
  bne t0, s7, fail
  csrr t0, 0x643
  bne t0, s6, fail
  csrr t0, 0x600
  andi t0, t0, 0xc0
  bne t0, s5, fail
  addi s0, s0, 1
  bnez s10, leave_guest
  csrr t0, sepc
  addi t0, t0, 4
  csrw sepc, t0
  sret
leave_guest:
  li t0, 0x80
  csrc 0x600, t0
  la t0, hs_done
  csrw sepc, t0
  sret

.balign 4
vs_trap:
  csrr t0, scause
  bltz t0, vs_interrupt
  bne t0, s3, guest_fail
  csrr t0, stval
  bne t0, s4, guest_fail
  addi s1, s1, 1
  csrr t0, sepc
  addi t0, t0, 4
  csrw sepc, t0
  sret
vs_interrupt:
  li t1, (1 << 63) | 5
  beq t0, t1, vs_timer
  li t1, (1 << 63) | 1
  bne t0, t1, guest_fail
  csrr t0, stval
  bnez t0, guest_fail
  li t0, 2
  csrc sip, t0
  addi s2, s2, 1
  sret
vs_timer:
  csrr t0, stval
  bnez t0, guest_fail
  li t0, -1
  csrw 0x14d, t0
  addi s9, s9, 1
  sret

guest_fail:
  li s10, -1
  ecall

fail:
  mv a0, s11
finish:
#ifdef SPIKE_HTIF
  slli a0, a0, 1
  ori a0, a0, 1
  la t0, tohost
  sd a0, 0(t0)
#else
  li t0, 0x100000
  li t1, 0x5555
  beqz a0, finish_write
  slli a0, a0, 16
  li t1, 0x3333
  or t1, t1, a0
finish_write:
  sw t1, 0(t0)
#endif
finish_wait:
  j finish_wait

.section .data
.balign 8
guest_data:
  .dword 0
guest_vector:
  .zero 16
.balign 64
.globl tohost
tohost:
  .dword 0
.globl fromhost
fromhost:
  .dword 0

.section .bss
.balign 16384
g_root:
  .zero 16384
.balign 4096
vs_root:
  .zero 4096

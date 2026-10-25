#if __riscv_xlen != 64
#error "PMP high-address regression requires RV64"
#endif
/* A retained high pmpaddr bit must not grant a low-address MPRV/U load.
 * The implemented pmpaddr width follows the platform physical-address width,
 * so the test discovers it instead of assuming 56-bit physical addresses. */
.option norvc
.option norelax
.section .text
.globl _start
_start:
  la t0, trap
  csrw mtvec, t0
  csrw mstatus, zero
  li t0, -1
  csrw pmpaddr15, t0
  li t0, 0x1800000000000000  /* background NAPOT, U denied, M bypass */
  csrw pmpcfg2, t0
  la s0, data
  /* pmpaddr is WARL: discover the implemented width W (bits [W+1:2]). */
  li t0, -1
  csrw pmpaddr0, t0
  csrr t0, pmpaddr0
  li s5, 0
width_scan:
  beqz t0, width_done
  srli t0, t0, 1
  addi s5, s5, 1
  j width_scan
width_done:
  li t1, 30                 /* must cover data's address bits [31:2] */
  blt s5, t1, fail
  li t1, 54                 /* RV64 architectural maximum */
  bgt s5, t1, fail
  /* Toggle implemented high page bits, including bits set in the data address. */
  li s1, 20
  li s3, 0
  bge s1, s5, positive_control
next_bit:
  srli t0, s0, 2
  li t1, 1
  sll t1, t1, s1
  xor t0, t0, t1
  csrw pmpcfg0, zero
  csrw pmpaddr0, t0
  csrr t2, pmpaddr0
  bne t2, t0, fail
  li t0, 0x19               /* NAPOT page grant at a different address */
  csrw pmpcfg0, t0
  sfence.vma
  la s2, denied_load
  li t0, 0x20000           /* MPRV=1, MPP=U */
  csrs mstatus, t0
denied_load:
  lbu t1, 0(s0)
  csrc mstatus, t0
  addi t2, s1, -19
  bne s3, t2, fail
  addi s1, s1, 1
  blt s1, s5, next_bit
  /* Positive control: the actual low page range must grant the same access. */
positive_control:
  srli t0, s0, 2
  csrw pmpaddr0, t0
  li t0, 0x19               /* minimum NAPOT page read grant */
  csrw pmpcfg0, t0
  sfence.vma
  li t0, 0x20000
  csrs mstatus, t0
allowed_load:
  lbu t1, 0(s0)
  csrc mstatus, t0
  li t2, 0x5a
  bne t1, t2, fail
  li a0, 0
  ebreak
trap:
  li t0, 0x20000
  csrc mstatus, t0
  csrr t1, mcause
  li t2, 5
  bne t1, t2, fail
  csrr t1, mtval
  bne t1, s0, fail
  csrr t1, mepc
  bne t1, s2, fail
  addi t1, t1, 4
  csrw mepc, t1
  addi s3, s3, 1
  mret
fail:
  li a0, 1
  ebreak
  j fail
.section .data
.balign 4096
data:
  .byte 0x5a
  .space 15

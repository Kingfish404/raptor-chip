/* Device and ROM atomic PMAs: fault before reads, writes or reservation. */
#if __riscv_xlen == 64
#define FAULTS_PER_REGION 6
#define REG_S sd
#define SATP_MODE 0x8000000000000000
#else
#define FAULTS_PER_REGION 3
#define REG_S sw
#define SATP_MODE 0x80000000
#endif
.option norvc
.option norelax
.section .text
.globl _start
_start:
  la t0, machine_trap
  csrw mtvec, t0
  csrw medeleg, zero
  csrw mie, zero
  li t0, -1
  csrw pmpaddr0, t0
  li t0, 0x1f
  csrw pmpcfg0, t0
  li t0, 0xf0
  csrw menvcfg, t0
  li s7, 0
  li s9, 0x02000000
  jal ra, test_readonly
  li s9, 0x20001000
  jal ra, test_readonly
  li s9, 0x30001000
  jal ra, test_readonly
  li t0, (3 * FAULTS_PER_REGION)
  bne s7, t0, fail
  la s0, root
  li t0, 0x200000cf
#if __riscv_xlen == 64
  sd t0, 16(s0)
  la t0, level1
  srli t0, t0, 2
  ori t0, t0, 1
  sd t0, 8(s0)
  la t0, level0
  srli t0, t0, 2
  ori t0, t0, 1
  la t1, level1
  sd t0, 0(t1)
#else
  li t1, 2048
  add t1, s0, t1
  sw t0, 0(t1)
  la t0, level0
  srli t0, t0, 2
  ori t0, t0, 1
  sw t0, 1024(s0)
#endif
  li t0, 0x008000cf /* CLINT 0x02000000, V/R/W/X/A/D */
  la t1, level0
  REG_S t0, 0(t1)
  srli t0, s0, 12
  li t1, SATP_MODE
  or t0, t0, t1
  csrw satp, t0
  sfence.vma
  li t0, 0x800
  csrw mstatus, t0
  la t0, supervisor
  csrw mepc, t0
  mret
supervisor:
  li s9, 0x40000000
  jal ra, test_readonly
  li t0, (4 * FAULTS_PER_REGION)
  bne s7, t0, fail
  ecall
  j fail
test_readonly:
  li s4, 0x55
  li t2, 1
  li s6, 5
  la s8, lr_test
  la s11, lr_resume
lr_test:
  lr.w s4, (s9)
lr_resume:
  li t0, 0x55
  bne s4, t0, fail
  li s6, 7
  la s8, sc_test
  la s11, sc_resume
sc_test:
  sc.w s4, t2, (s9)
sc_resume:
  li t0, 0x55
  bne s4, t0, fail
  la s8, amo_test
  la s11, amo_resume
amo_test:
  amoadd.w s4, t2, (s9)
amo_resume:
  li t0, 0x55
  bne s4, t0, fail
#if __riscv_xlen == 64
  li s6, 5
  la s8, lrd_test
  la s11, lrd_resume
lrd_test:
  lr.d s4, (s9)
lrd_resume:
  li t0, 0x55
  bne s4, t0, fail
  li s6, 7
  la s8, scd_test
  la s11, scd_resume
scd_test:
  sc.d s4, t2, (s9)
scd_resume:
  li t0, 0x55
  bne s4, t0, fail
  la s8, amod_test
  la s11, amod_resume
amod_test:
  amoadd.d s4, t2, (s9)
amod_resume:
  li t0, 0x55
  bne s4, t0, fail
#endif
  ret
machine_trap:
  csrr t0, mcause
  li t1, 9
  beq t0, t1, restore_ram
  bne t0, s6, fail
  csrr t0, mepc
  bne t0, s8, fail
  csrr t0, mtval
  bne t0, s9, fail
  addi s7, s7, 1
  csrw mepc, s11
  mret
restore_ram:
  la t0, ram_page
  srli t0, t0, 2
  ori t0, t0, 0xcf
  la t1, level0
  REG_S t0, 0(t1)
  sfence.vma
  la t0, test_ram
  csrw mepc, t0
  mret
test_ram:
  li t2, 7
  sw t2, 0(s9)
  lr.w s4, (s9)
  li t0, 7
  bne s4, t0, fail
  li t2, 8
  sc.w s4, t2, (s9)
  bnez s4, fail
  li t2, 1
  amoadd.w s4, t2, (s9)
  li t0, 8
  bne s4, t0, fail
  lw t0, 0(s9)
  li t1, 9
  bne t0, t1, fail
#if __riscv_xlen == 64
  li t2, 0x1234567800000007
  sd t2, 0(s9)
  lr.d s4, (s9)
  bne s4, t2, fail
  addi t2, t2, 1
  sc.d s4, t2, (s9)
  bnez s4, fail
  li t3, 1
  amoadd.d s4, t3, (s9)
  bne s4, t2, fail
  ld t0, 0(s9)
  addi t2, t2, 1
  bne t0, t2, fail
#endif
  li a0, 0
  ebreak
fail:
  li a0, 1
  ebreak
  j fail
.section .data
.balign 4096
root: .zero 4096
level1: .zero 4096
level0: .zero 4096
ram_page: .zero 4096

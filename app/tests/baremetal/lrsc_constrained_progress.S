/* Finite stress of maximal 16-instruction or minimal 3-instruction LR/SC loops.
 * No interrupt or software retry-limit escape is counted as success. The
 * simulator timeout is an external test budget, not an ISA latency bound.
 */
#ifndef TEST_PRIV
#define TEST_PRIV 3
#endif
#ifndef CODE_OFFSET
#define CODE_OFFSET 0
#endif
#ifndef ORDERED
#define ORDERED 0
#endif
#ifndef TEST_D
#define TEST_D 0
#endif
#ifndef TEST_VM
#define TEST_VM 0
#endif
#ifndef SHORT_LOOP
#define SHORT_LOOP 0
#endif
#if TEST_VM && (__riscv_xlen != 64 || TEST_PRIV == 3)
#error Sv39 progress tests require RV64 S/U mode
#endif
#if TEST_PRIV == 0
#define USER_PTE 0x10
#else
#define USER_PTE 0
#endif
#if TEST_D
#define ATOMIC_BYTES 8
#define LOAD ld
#define STORE sd
#if ORDERED
#define LR lr.d.aq
#define SC sc.d.rl
#else
#define LR lr.d
#define SC sc.d
#endif
#else
#define ATOMIC_BYTES 4
#define LOAD lw
#define STORE sw
#if ORDERED
#define LR lr.w.aq
#define SC sc.w.rl
#else
#define LR lr.w
#define SC sc.w
#endif
#endif
.option norvc
.option norelax
.section .text
.globl _start
_start:
  la t0, fail
  csrw mtvec, t0
  csrw mie, zero
  csrw medeleg, zero
  csrw satp, zero
  li t0, -1
  csrw pmpaddr0, t0
  li t0, 0x1f
  csrw pmpcfg0, t0
#if TEST_VM
  /* Actual Sv39 walks, with 4 KiB code and data leaves. Code stays at its
   * linked VA; data aliases at 0x40000000/0x40200000/0x40400000 are distinct
   * from all three physical RAM addresses. Tables have file-backed zeros. */
  la t0, vm_root
  li t1, (0xcf | USER_PTE)
  sd t1, 0(t0)                 /* Finisher: identity first GiB. */
  la t1, vm_data_l1
  srli t1, t1, 2
  ori t1, t1, 1
  sd t1, 8(t0)
  la t1, vm_code_l1
  srli t1, t1, 2
  ori t1, t1, 1
  sd t1, 16(t0)
  la t0, vm_code_l1
  la t1, vm_code_l0
  srli t1, t1, 2
  ori t1, t1, 1
  sd t1, 0(t0)
  la t0, vm_code_l0
  li t1, (0x20000000 | 0xcb | USER_PTE)
  li t2, 32                   /* 128 KiB identity code window, read/execute. */
3:
  sd t1, 0(t0)
  addi t0, t0, 8
  addi t1, t1, 1024
  addi t2, t2, -1
  bnez t2, 3b
  la t0, vm_data_l1
  la t1, vm_ram0_l0
  srli t1, t1, 2
  ori t1, t1, 1
  sd t1, 0(t0)
  la t1, vm_ram1_l0
  srli t1, t1, 2
  ori t1, t1, 1
  sd t1, 8(t0)
  la t1, vm_ram2_l0
  srli t1, t1, 2
  ori t1, t1, 1
  sd t1, 16(t0)
  la t0, vm_ram0_l0
  li t1, ((0x0f000000 >> 2) | 0xc7 | USER_PTE)
  sd t1, 0(t0)
  la t0, vm_ram1_l0
  li t1, ((0x80400000 >> 2) | 0xc7 | USER_PTE)
  sd t1, 0(t0)
  la t0, vm_ram2_l0
  li t1, ((0xa0000000 >> 2) | 0xc7 | USER_PTE)
  sd t1, 0(t0)
  la t0, vm_root
  srli t0, t0, 12
  li t1, (8 << 60)
  or t0, t0, t1
  csrw satp, t0
  csrr t1, satp
  bne t0, t1, fail
  sfence.vma
#endif
  la t0, run
  csrw mepc, t0
  li t0, (TEST_PRIV << 11)
  csrw mstatus, t0
  mret
run:
  li s0, 0
region:
#if TEST_VM
  li s1, 0x40000000
  beqz s0, base_ready
  li s1, 0x40200000
  li t0, 1
  beq s0, t0, base_ready
  li s1, 0x40400000
#else
  li s1, 0x0f000000
  beqz s0, base_ready
  li s1, 0x80400000
  li t0, 1
  beq s0, t0, base_ready
  li s1, 0xa0000000
#endif
base_ready:
  li s2, 0
position:
  mv a0, s1
  beqz s2, address_ready
  addi a0, s1, (64-ATOMIC_BYTES)
  li t0, 1
  beq s2, t0, address_ready
  addi a0, s1, 64
  li t0, 2
  beq s2, t0, address_ready
  li t0, (4096-ATOMIC_BYTES)
  add a0, s1, t0
address_ready:
  STORE zero, 0(a0)
  li s3, 32
  li s4, 0
increment:
#if SHORT_LOOP
  addi a1, s4, 1
#endif
  la t0, maximal_loop
  jalr ra, t0, 0
  addi s4, s4, 1
  LOAD t0, 0(a0)
  bne t0, s4, fail
  addi s3, s3, -1
  bnez s3, increment
  addi s2, s2, 1
  li t0, 4
  bne s2, t0, position
  addi s0, s0, 1
  li t0, 3
  bne s0, t0, region
  li t0, 0x00100000
  li t1, 0x5555
  sw t1, 0(t0)
1: j 1b
fail:
  li t0, 0x00100000
  li t1, 0x3333
  sw t1, 0(t0)
2: j 2b
/* Exercise up to a cache-line/page boundary; offset 2 also straddles
 * native instructions across fetch words. TEST_VM maps code with 4 KiB leaves. */
.balign 4096
.space (4032+CODE_OFFSET), 0
.globl maximal_loop
maximal_loop:
#if SHORT_LOOP
  LR zero, (a0)
#ifdef INJECT_SC_FAIL
  li t1, 1
#else
  SC t1, a1, (a0)
#endif
#else
  LR t0, (a0)
  addi t0, t0, 1
  .rept 12
  addi zero, zero, 0
  .endr
#ifdef INJECT_SC_FAIL
  li t1, 1
#else
  SC t1, t0, (a0)
#endif
#endif
  bnez t1, maximal_loop
.globl maximal_loop_end
maximal_loop_end:
  ret
#if TEST_VM
.section .data
.balign 4096
vm_root: .zero 4096
vm_code_l1: .zero 4096
vm_code_l0: .zero 4096
vm_data_l1: .zero 4096
vm_ram0_l0: .zero 4096
vm_ram1_l0: .zero 4096
vm_ram2_l0: .zero 4096
#endif

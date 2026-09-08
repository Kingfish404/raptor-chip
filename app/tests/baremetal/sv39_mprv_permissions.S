/* Actual M-mode execution with MPRV data translation. SATP deliberately has
 * NO code mapping: successful execution shows MPRV does not translate fetch.
 * Compile with MPP_MODE, PAGE_USER, USE_SUM, USE_MXR and EXEC_ONLY (0/1).
 */
#ifndef MPP_MODE
#define MPP_MODE 1
#endif
#ifndef PAGE_USER
#define PAGE_USER 0
#endif
#ifndef USE_SUM
#define USE_SUM 0
#endif
#ifndef USE_MXR
#define USE_MXR 0
#endif
#ifndef EXEC_ONLY
#define EXEC_ONLY 0
#endif
#define MODE_OK ((MPP_MODE == 0) ? PAGE_USER : (!PAGE_USER || USE_SUM))
#define LOAD_OK (MODE_OK && (!EXEC_ONLY || USE_MXR))
#define STORE_OK (MODE_OK && !EXEC_ONLY)
#if LOAD_OK
#define LOAD_FAILURE 0
#else
#define LOAD_FAILURE 1
#endif
#if STORE_OK
#define STORE_FAILURE 0
#else
#define STORE_FAILURE 1
#endif
#define STATUS (0x20000 | (MPP_MODE << 11) | (USE_SUM << 18) | (USE_MXR << 19))
.option norvc
.option norelax
.section .text
.globl _start, test_load, test_store
_start:
  la t0, machine_trap
  csrw mtvec, t0
  csrw mie, zero
  csrw medeleg, zero
  li t0, -1
  csrw pmpaddr0, t0
  li t0, 0x1f
  csrw pmpcfg0, t0
  la t0, root
  la t1, level1
  srli t1, t1, 2
  ori t1, t1, 1
  sd t1, 8(t0)
  la t0, level1
  la t1, level0
  srli t1, t1, 2
  ori t1, t1, 1
  sd t1, 0(t0)
  la t0, level0
  la t1, data_page
  srli t1, t1, 2
#if EXEC_ONLY
  ori t1, t1, (0xc9 | (PAGE_USER << 4))
#else
  ori t1, t1, (0xc7 | (PAGE_USER << 4))
#endif
  sd t1, 0(t0)
  la t0, root
  srli t0, t0, 12
  li t1, (8 << 60)
  or t0, t0, t1
  csrw satp, t0
  csrr t1, satp
  bne t0, t1, fail
  sfence.vma
  li s7, 0
  li a0, 0x40000000
  li a2, -1
  li s8, 13
  la s11, test_load
  la s9, after_load
  li t0, STATUS
  csrw mstatus, t0
test_load:
  ld a2, 0(a0)
after_load:
  li t0, 0x20000
  csrc mstatus, t0
#if LOAD_OK
  li t0, 0x11223344
#else
  li t0, -1
#endif
  bne a2, t0, fail
  li a1, 0x55667788
  li s8, 15
  la s11, test_store
  la s9, after_store
  li t0, STATUS
  csrw mstatus, t0
test_store:
  sd a1, 0(a0)
after_store:
  li t0, 0x20000
  csrc mstatus, t0
  li t0, (LOAD_FAILURE + STORE_FAILURE)
  bne s7, t0, fail
  la t0, data_page
  ld t1, 0(t0)
#if STORE_OK
  li t0, 0x55667788
#else
  li t0, 0x11223344
#endif
  bne t0, t1, fail
  li t0, 0x00100000
  li t1, 0x5555
  sw t1, 0(t0)
1: j 1b
.balign 4, 0
machine_trap:
  li t0, 0x20000
  csrc mstatus, t0
  la t2, trap_records
  slli t3, s7, 5
  add t2, t2, t3
  csrr t0, mcause
  sd t0, 0(t2)
  bne t0, s8, fail
  csrr t0, mtval
  sd t0, 8(t2)
  bne t0, a0, fail
  csrr t0, mepc
  sd t0, 16(t2)
  bne t0, s11, fail
  addi s7, s7, 1
  csrw mepc, s9
  mret
fail:
  li t0, 0x20000
  csrc mstatus, t0
  li t0, 0x00100000
  li t1, 0x3333
  sw t1, 0(t0)
2: j 2b
.section .data
.balign 4096
root: .zero 4096
level1: .zero 4096
level0: .zero 4096
data_page: .dword 0x11223344
.balign 8
.globl trap_records, trap_records_end
trap_records: .zero 96
trap_records_end:

/* Cycle-based F/D scheduling comparison. Build each BENCH_CASE and FP_DOUBLE
 * once, then run identical binaries on both RTL revisions. Four warmup loops
 * precede a fixed-length ROI; UART output and result checks are outside it.
 * Cases: integer control, independent ADD, ADD chain, independent MUL,
 * independent FMA, FMA chain, DIV stream, DIV/integer overlap, load/add/store,
 * DIV/ADD overlap.
 */
#ifndef BENCH_CASE
#define BENCH_CASE 1
#endif
#ifndef FP_DOUBLE
#define FP_DOUBLE 0
#endif
#ifndef ITERATIONS
#define ITERATIONS 64
#endif
#ifndef PRELOAD_OUTPUT
#define PRELOAD_OUTPUT 0
#endif
#if FP_DOUBLE
#define FADD fadd.d
#define FMUL fmul.d
#define FMADD fmadd.d
#define FDIV fdiv.d
#define FROM_INT fcvt.d.w
#define TO_INT fcvt.w.d
#define FLOAD fld
#define FSTORE fsd
#define STRIDE 8
#else
#define FADD fadd.s
#define FMUL fmul.s
#define FMADD fmadd.s
#define FDIV fdiv.s
#define FROM_INT fcvt.s.w
#define TO_INT fcvt.w.s
#define FLOAD flw
#define FSTORE fsw
#define STRIDE 4
#endif

.section .text
.globl _start
.option norvc
_start:
  li t0, 0x6000
  csrs mstatus, t0
  csrwi fcsr, 0
  li t0, 1
  FROM_INT f1, t0
  li t0, 3
  FROM_INT f2, t0
  li t0, 7
  FROM_INT f3, t0
  FROM_INT f8, zero
  la s7, inputs
  la s8, outputs
#if BENCH_CASE == 8 && PRELOAD_OUTPUT
  /* Partial-word store misses do not allocate in the tested L1D. Optional
   * reads make the output words resident for the cache-hit comparison. */
  FLOAD f8, 0(s8)
  FLOAD f9, STRIDE(s8)
  FLOAD f10, 2*STRIDE(s8)
  FLOAD f11, 3*STRIDE(s8)
#endif
  li s0, 4
  jal s6, kernel

  FROM_INT f8, zero
  li t0, 0
  li t1, 0
  li t2, 0
  li t3, 0
  li s0, ITERATIONS
  /* The run is far shorter than 2^32 cycles, including on RV32. CSR
   * serialization drains the ROB at the timing boundaries on both designs. */
  rdcycle s2
  rdinstret s3
  jal s6, kernel
  rdinstret s4
  rdcycle s5
  sub s5, s5, s2
  sub s4, s4, s3

#if BENCH_CASE == 0 || BENCH_CASE == 7
  li t4, ITERATIONS * 16
  bne t0, t4, fail
  bne t1, t4, fail
  bne t2, t4, fail
  bne t3, t4, fail
#elif BENCH_CASE == 1 || BENCH_CASE == 9
  TO_INT t0, f8, rtz
  li t1, 4
  bne t0, t1, fail
#elif BENCH_CASE == 2
  TO_INT t0, f8, rtz
  li t1, ITERATIONS * 16
  bne t0, t1, fail
#elif BENCH_CASE == 3
  TO_INT t0, f8, rtz
  li t1, 3
  bne t0, t1, fail
#elif BENCH_CASE == 4
  TO_INT t0, f8, rtz
  li t1, 10
  bne t0, t1, fail
#elif BENCH_CASE == 5
  TO_INT t0, f8, rtz
  li t1, ITERATIONS * 16 * 3
  bne t0, t1, fail
#elif BENCH_CASE == 6
  TO_INT t0, f8, rtz
  bnez t0, fail
#elif BENCH_CASE == 8
  FLOAD f8, 0(s8)
  FLOAD f9, STRIDE(s8)
  FLOAD f10, 2*STRIDE(s8)
  FLOAD f11, 3*STRIDE(s8)
  li t1, 4
  TO_INT t0, f8, rtz
  bne t0, t1, fail
  TO_INT t0, f9, rtz
  bne t0, t1, fail
  TO_INT t0, f10, rtz
  bne t0, t1, fail
  TO_INT t0, f11, rtz
  bne t0, t1, fail
#endif
  la a0, cycles_label
  call puts
  mv a0, s5
  call hex
  la a0, instret_label
  call puts
  mv a0, s4
  call hex
  la a0, newline
  call puts
  li a0, 0
  ebreak
fail:
  li a0, 1
  ebreak

.balign 64
kernel:
#if BENCH_CASE == 0 || BENCH_CASE == 7
#if BENCH_CASE == 7
  FDIV f8, f2, f3
#endif
  .rept 16
    addi t0, t0, 1
    addi t1, t1, 1
    addi t2, t2, 1
    addi t3, t3, 1
  .endr
#elif BENCH_CASE == 1
  .rept 16
    FADD f8, f1, f2
  .endr
#elif BENCH_CASE == 2
  .rept 16
    FADD f8, f8, f1
  .endr
#elif BENCH_CASE == 3
  .rept 16
    FMUL f8, f1, f2
  .endr
#elif BENCH_CASE == 4
  .rept 16
    FMADD f8, f1, f2, f3
  .endr
#elif BENCH_CASE == 5
  .rept 16
    FMADD f8, f8, f1, f2
  .endr
#elif BENCH_CASE == 6
  .rept 4
    FDIV f8, f2, f3
  .endr
#elif BENCH_CASE == 8
  FLOAD f8, 0(s7)
  FLOAD f9, STRIDE(s7)
  FLOAD f10, 2*STRIDE(s7)
  FLOAD f11, 3*STRIDE(s7)
  FADD f8, f8, f2
  FADD f9, f9, f2
  FADD f10, f10, f2
  FADD f11, f11, f2
  FSTORE f8, 0(s8)
  FSTORE f9, STRIDE(s8)
  FSTORE f10, 2*STRIDE(s8)
  FSTORE f11, 3*STRIDE(s8)
#elif BENCH_CASE == 9
  FDIV f12, f2, f3
  .rept 16
    FADD f8, f1, f2
  .endr
#else
#error unsupported BENCH_CASE
#endif
  addi s0, s0, -1
  bnez s0, kernel
  jr s6

/* Leaf UART routines. Fixed-width hex avoids data-dependent output lengths. */
puts:
  li t0, 0x10000000
1:
  lbu t1, 0(a0)
  beqz t1, 2f
  sb t1, 0(t0)
  addi a0, a0, 1
  j 1b
2:
  ret
hex:
  li t0, 0x10000000
  li t1, __riscv_xlen - 4
1:
  srl t2, a0, t1
  andi t2, t2, 15
  li t3, 10
  bltu t2, t3, 2f
  addi t2, t2, 39
2:
  addi t2, t2, 48
  sb t2, 0(t0)
  addi t1, t1, -4
  bgez t1, 1b
  ret

.section .rodata
cycles_label: .asciz "FP_PERF cycles="
instret_label: .asciz " instret="
newline: .asciz "\n"
.balign 64
inputs:
#if FP_DOUBLE
  .rept 4
    .quad 0x3ff0000000000000
  .endr
#else
  .rept 4
    .word 0x3f800000
  .endr
#endif
.section .data
.balign 64
outputs: .zero 32

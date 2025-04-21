#define PRV_U 0x0
#define PRV_S 0x1
#define PRV_M 0x3

#define concat_temp(x, y) x ## y
#define concat(x, y) concat_temp(x, y)
#define MAP(c, f) c(f)

#if __riscv_xlen == 32
#define LOAD  lw
#define STORE sw
#define XLEN  4
#else
#define LOAD  ld
#define STORE sd
#define XLEN  8
#endif

#define REGS_LO16(f) \
      f( 1)       f( 3) f( 4) f( 5) f( 6) f( 7) f( 8) f( 9) \
f(10) f(11) f(12) f(13) f(14) f(15)
#ifndef __riscv_e
#define REGS_HI16(f) \
                                    f(16) f(17) f(18) f(19) \
f(20) f(21) f(22) f(23) f(24) f(25) f(26) f(27) f(28) f(29) \
f(30) f(31)
#define NR_REGS 32
#else
#define REGS_HI16(f)
#define NR_REGS 16
#endif

#define REGS(f) REGS_LO16(f) REGS_HI16(f)

#define PUSH(n) STORE concat(x, n), (n * XLEN)(sp);
#define POP(n)  LOAD  concat(x, n), (n * XLEN)(sp);

#define CONTEXT_SIZE  ((NR_REGS + 3 + 2) * XLEN)
#define OFFSET_SP     ((2) * XLEN)
#define OFFSET_CAUSE  ((NR_REGS + 0) * XLEN)
#define OFFSET_STATUS ((NR_REGS + 1) * XLEN)
#define OFFSET_EPC    ((NR_REGS + 2) * XLEN)
#define OFFSET_NP     ((NR_REGS + 4) * XLEN)

.align 3
.globl __am_asm_trap
__am_asm_trap:
  csrrw sp, mscratch, sp // (1) atomically exchange sp and mscratch
  bnez sp, save_context  // (2) take the branch if we trapped from user
  csrrw sp, mscratch, sp // (3) if we trapped from kernel, restore the original sp

save_context:
  // TODO: pa4 is not yet correctly implemented
  // now sp is pointing to the kernel stack
  // save the context...
  addi sp, sp, -CONTEXT_SIZE

  MAP(REGS, PUSH)

  csrr t0, mcause
  csrr t1, mstatus
  csrr t2, mepc

  STORE t0, OFFSET_CAUSE(sp)
  STORE t1, OFFSET_STATUS(sp)
  STORE t2, OFFSET_EPC(sp)

  // c->np = (ksp == 0 ? KERNEL : USER);  // np should be in Context
  li t0, PRV_M
  STORE t0, OFFSET_NP(sp)
  csrr t0, mscratch
  beqz t0, trap_handle
  addi t0, t0, -CONTEXT_SIZE
  STORE t0, OFFSET_SP(sp)
  li t1, PRV_U
  STORE t1, OFFSET_NP(sp)

trap_handle:
  # set mstatus.MPRV to pass difftest
  li a0, (1 << 17)
  or t1, t1, a0
  csrw mstatus, t1

  // ksp = 0;
  // csrw mscratch, zero

  mv a0, sp
  jal __am_irq_handle
  mv sp, a0

  LOAD t1, OFFSET_STATUS(sp)
  LOAD t2, OFFSET_EPC(sp)
  csrw mstatus, t1
  csrw mepc, t2

  // if (c->np == USER) { ksp = $sp; }
  LOAD t0, OFFSET_NP(sp)
  li t1, PRV_U
  bne t0, t1, restore_context
  mv t0, sp
  addi t0, t0, CONTEXT_SIZE
  csrw mscratch, t0 // ksp = $sp

restore_context:
  MAP(REGS, POP)

  addi sp, sp, CONTEXT_SIZE
  mret

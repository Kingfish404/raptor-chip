/* Each case has an independently named architectural owner. The following
 * instructions deliberately have visible effects if a step leaks admission. */
.section .text
.option norvc
.cfi_sections .debug_frame
.global _start
_start:
  j _start

.macro test_case name, instruction:vararg
  .balign 16
  .global \name, \name\()_next
\name:
  \instruction
\name\()_next:
  lw t6, 0(s0)
  sw t6, 0(s0)
  j _start
.endm

test_case alu, addi t2, t2, 1
test_case load, lw t2, 0(t0)
test_case store, sw t1, 0(t0)
test_case amo, amoadd.w t2, t1, (t0)
test_case lr, lr.w t2, (t0)
test_case sc, sc.w t2, t1, (t0)
test_case csr, csrw mscratch, t0
test_case csr_read, csrr t2, mscratch
test_case fence_i, fence.i
test_case ecall, ecall
test_case illegal, .word 0xffffffff
test_case wfi, wfi
test_case mtvec, csrw mtvec, t0
test_case mie, csrw mie, t0
test_case mstatus, csrw mstatus, t0
test_case mepc, csrw mepc, t0
test_case pmpaddr, csrw pmpaddr0, t0
test_case pmpcfg, csrw pmpcfg0, t0
test_case mret, mret
test_case ebreak, ebreak
test_case mcause, csrr t2, mcause
test_case mepc_read, csrr t2, mepc
test_case mtval, csrr t2, mtval

.balign 16
.global branch, branch_next, branch_target
branch:
  beq t0, t1, branch_target
branch_next:
  lw t6, 0(s0)
  sw t6, 0(s0)
branch_target:
  j _start

.balign 16
.global jump, jump_target
jump:
  jal ra, jump_target
  lw t6, 0(s0)
  sw t6, 0(s0)
jump_target:
  j _start

.balign 16
.global indirect
indirect:
  jalr ra, t0, 0
  lw t6, 0(s0)
  sw t6, 0(s0)

.balign 16
.option rvc
.global compressed, compressed_next, c_ebreak, c_ebreak_next
compressed:
  c.addi t2, 1
compressed_next:
  c.addi t3, 1
c_ebreak:
  c.ebreak
c_ebreak_next:
  c.nop
.option norvc
  j _start

.balign 16
.global swbreak, swbreak_next, call_test, callee, callee_body, call_next
.option rvc
swbreak:
  c.addi t2, 1
swbreak_next:
  c.addi t3, 1
.option norvc
  j swbreak
.type call_test, @function
call_test:
  jal ra, callee
call_next:
  j call_next
.size call_test, . - call_test
.type callee, @function
callee:
  .cfi_startproc
  addi sp, sp, -16
  .cfi_def_cfa_offset 16
#if __riscv_xlen == 64
  sd ra, 8(sp)
  .cfi_offset ra, -8
#else
  sw ra, 12(sp)
  .cfi_offset ra, -4
#endif
callee_body:
  addi t2, t2, 1
#if __riscv_xlen == 64
  ld ra, 8(sp)
#else
  lw ra, 12(sp)
#endif
  .cfi_restore ra
  addi sp, sp, 16
  .cfi_def_cfa_offset 0
  ret
  .cfi_endproc
.size callee, . - callee

.balign 64
.global handler
handler:
  addi t5, t5, 1
  j handler

.section .data
.balign 64
.global data
data:
  .word 7, 0x12345678, 0x89abcdef, 0

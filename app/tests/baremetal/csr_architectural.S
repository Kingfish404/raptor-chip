/* Whole-core M-mode CSR state/view checks. Hardware SEIP RMW is exercised
 * with an external source in tb_csr_architectural; this program verifies
 * the normal decoded instructions and differential architectural state.
 */
.option norvc
.option norelax
.section .text
.globl _start
#if __riscv_xlen == 64
#define MSTATUS_HW 0x0000000a00000000
#define SSTATUS_HW 0x0000000200000000
#define SD 0x8000000000000000
#else
#define MSTATUS_HW 0
#define SSTATUS_HW 0
#define SD 0x80000000
#endif
_start:
  la t0, fail
  csrw mtvec, t0
  csrw mstatus, zero
  li s0, 0
delegation:
  andi t0, s0, 1
  slli t0, t0, 1
  andi t1, s0, 2
  slli t1, t1, 4
  or t0, t0, t1
  andi t1, s0, 4
  slli t1, t1, 7
  or t0, t0, t1
  csrw mideleg, t0
  li t1, -1
  csrw mie, t1
  csrr t2, mie
  li t3, 0x10aaa
  bne t2, t3, fail
  li t1, 0x222
  csrw mip, t1
  csrr t2, sie
  bne t2, t0, fail
  csrr t2, sip
  bne t2, t0, fail
  csrw sie, zero
  csrr t2, mie
  xori t3, t0, -1
  li t4, 0x10aaa
  and t3, t3, t4
  bne t2, t3, fail
  csrw sip, zero
  csrr t2, mip
  andi t3, t0, 2
  xori t3, t3, -1
  and t3, t3, t1
  bne t2, t3, fail
  addi s0, s0, 1
  li t0, 8
  blt s0, t0, delegation
  csrw mie, zero
  csrw mip, zero
  csrw mideleg, zero
  csrr s2, misa
  srli s2, s2, 21
  andi s2, s2, 1
  neg s2, s2
  andi s2, s2, 0x600  /* VS is writable only when MISA.V is present. */
  li s0, 0
status_fields:
  andi s1, s0, 3
  slli s1, s1, 13
  srli s3, s0, 2
  slli s3, s3, 9
  li t0, 0x18040        /* XS=3 and UBE=1 remain read-only zero. */
  or t0, t0, s1
  or t0, t0, s3
  li t1, SD
  or t0, t0, t1
  csrw mstatus, t0
  and s3, s3, s2
  or s1, s1, s3
  andi t2, s0, 3
  li t3, 3
  beq t2, t3, dirty
  li t3, 0x600
  bne s3, t3, clean
dirty:
  or s1, s1, t1
clean:
  li t1, MSTATUS_HW
  or t1, t1, s1
  csrr t2, mstatus
  bne t1, t2, fail
  li t1, SSTATUS_HW
  or t1, t1, s1
  csrr t2, sstatus
  bne t1, t2, fail
  csrw sstatus, zero
  csrr t2, mstatus
  li t1, MSTATUS_HW
  bne t1, t2, fail
  csrr t2, sstatus
  li t1, SSTATUS_HW
  bne t1, t2, fail
  addi s0, s0, 1
  li t0, 16
  blt s0, t0, status_fields
  li t0, 0x1000        /* unsupported MPP=2 must not read back */
  csrw mstatus, t0
  csrr t1, mstatus
  srli t1, t1, 11
  andi t1, t1, 3
  li t2, 2
  beq t1, t2, fail
  /* Reserved W=1/R=0 must legalize identically in CSR and PMP state.
   * A=OFF and L=0 keep these writes from restricting the test itself. */
  li t0, 2
  csrw pmpcfg0, t0
  csrr t1, pmpcfg0
  bnez t1, fail
  li t0, 6
  csrw pmpcfg0, t0
  csrr t1, pmpcfg0
  bnez t1, fail
  li t0, 7
  csrw pmpcfg0, t0
  csrr t1, pmpcfg0
  bne t1, t0, fail
  csrw pmpcfg0, zero
  li a0, 0
  ebreak
fail:
  li a0, 1
  ebreak
  j fail

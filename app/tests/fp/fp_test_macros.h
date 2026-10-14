/* Preserve each named failure code and the finisher write sequence. */
.macro FP_FAIL label, code
\label:
  li t0, 0x00100000
  li t1, \code
  sw t1, 0(t0)
.endm

/* Checks preserve the original t1/t2 scratch registers and failure labels. */
.macro FP_CHECK_T1 expected, failure
  li t2, \expected
  bne t1, t2, \failure
.endm

.macro FP_CHECK_FFLAGS expected, failure
  csrr t1, fflags
  .if \expected
    FP_CHECK_T1 \expected, \failure
  .else
    bnez t1, \failure
  .endif
.endm

.section .text.start, "ax"
.global _start
_start:
    csrw mie, zero
    li sp, 0x8001fff0
    call cm005_diag
    fence rw, rw
    fence.i
    li t0, 0x20000000
    jr t0

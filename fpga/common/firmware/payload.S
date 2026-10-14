.section .text.start, "ax"
.global _start
_start:
    li t0, 0x10000000
    la t1, message
1:  lbu t2, 0(t1)
    beqz t2, 3f
2:  lbu t3, 5(t0)
    andi t3, t3, 0x20
    beqz t3, 2b
    sb t2, 0(t0)
    addi t1, t1, 1
    j 1b
3:  wfi
    j 3b
message:
    .asciz "NATIVE PAYLOAD PASS\r\n"

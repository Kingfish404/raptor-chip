# Minimal FPGA bring-up firmware for Raptor LiteX on Tang Mega 138K
#
# This ROM is intentionally tiny and self-contained: it initializes the stack,
# prints a UART banner, and then idles. It does not assume any main RAM or DTB.

.equ UART_RXTX,   0xf0002000
.equ UART_TXFULL, 0xf0002004

.section .text
.global _start
_start:
    li      sp, 0x0f002000

    la      a0, msg_banner
    jal     ra, puts

1:  wfi
    j       1b

# puts: print null-terminated string at a0
puts:
    li      t0, UART_RXTX
    li      t1, UART_TXFULL
.Lputs_loop:
    lbu     t2, 0(a0)
    beqz    t2, .Lputs_done
.Lputs_wait:
    lw      t3, 0(t1)
    bnez    t3, .Lputs_wait
    sw      t2, 0(t0)
    addi    a0, a0, 1
    j       .Lputs_loop
.Lputs_done:
    ret

.section .rodata
msg_banner:
    .asciz "Raptor LiteX FPGA bring-up on Tang Mega 138K\n"

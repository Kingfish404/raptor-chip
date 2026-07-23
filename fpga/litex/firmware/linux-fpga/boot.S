/* Raptor KU15P Linux FPGA stage0.
 *
 * Loaded by LiteX BIOS serialboot at RAPT_MAIN_RAM. The BIOS initializes
 * LiteDRAM, then jumps here with no DTB argument. This stage0 relocates a tiny
 * copy routine to SRAM, moves the bundled OpenSBI fw_payload.bin back to its
 * link address, copies the DTB to RAPT_DTB_DEST, and jumps to OpenSBI with the
 * standard RISC-V boot ABI: a0=hartid, a1=FDT address.
 */

#ifndef RAPT_MAIN_RAM
#define RAPT_MAIN_RAM 0x80000000
#endif

#ifndef RAPT_STAGE0_SRAM
#define RAPT_STAGE0_SRAM 0x0f000000
#endif

#ifndef RAPT_PAYLOAD_SRC
#define RAPT_PAYLOAD_SRC 0x80100000
#endif

#ifndef RAPT_PAYLOAD_SIZE
#define RAPT_PAYLOAD_SIZE 0
#endif

#ifndef RAPT_DTB_SRC
#define RAPT_DTB_SRC 0x82000000
#endif

#ifndef RAPT_DTB_DEST
#define RAPT_DTB_DEST 0x83f00000
#endif

#ifndef RAPT_DTB_SIZE
#define RAPT_DTB_SIZE 0
#endif

#ifndef RAPT_UART_BASE
#define RAPT_UART_BASE 0xf0001800
#endif

.equ MAIN_RAM,     RAPT_MAIN_RAM
.equ STAGE0_SRAM,  RAPT_STAGE0_SRAM
.equ PAYLOAD_SRC,  RAPT_PAYLOAD_SRC
.equ PAYLOAD_SIZE, RAPT_PAYLOAD_SIZE
.equ DTB_SRC,      RAPT_DTB_SRC
.equ DTB_DEST,     RAPT_DTB_DEST
.equ DTB_SIZE,     RAPT_DTB_SIZE
.equ UART_RXTX,    RAPT_UART_BASE
.equ UART_TXFULL,  RAPT_UART_BASE + 4

.macro li_addr reg, val
    li      \reg, (((\val) >> 24) & 0xff)
    slli    \reg, \reg, 8
    ori     \reg, \reg, (((\val) >> 16) & 0xff)
    slli    \reg, \reg, 8
    ori     \reg, \reg, (((\val) >> 8) & 0xff)
    slli    \reg, \reg, 8
    ori     \reg, \reg, ((\val) & 0xff)
.endm

.section .text.init, "ax"
.global _start
_start:
    la      a0, msg_boot
    jal     ra, puts

    la      t0, _reloc_start
    la      t1, _reloc_end
    li_addr t2, STAGE0_SRAM
    mv      t3, t2
.Lcopy_reloc:
    bgeu    t0, t1, .Lcopy_reloc_done
    lbu     t4, 0(t0)
    sb      t4, 0(t2)
    addi    t0, t0, 1
    addi    t2, t2, 1
    j       .Lcopy_reloc
.Lcopy_reloc_done:
    fence   rw, rw
    fence.i
    jr      t3

puts:
    li_addr t0, UART_RXTX
    li_addr t1, UART_TXFULL
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

.align 2
_reloc_start:
    lla     a0, msg_payload_copy
    jal     ra, reloc_puts

    li_addr t0, PAYLOAD_SRC
    li_addr t1, MAIN_RAM
    li_addr t2, PAYLOAD_SIZE

    srli    t4, t2, 2
.Lcopy_payload_words:
    beqz    t4, .Lcopy_payload_tail
    lw      t3, 0(t0)
    sw      t3, 0(t1)
    addi    t0, t0, 4
    addi    t1, t1, 4
    addi    t4, t4, -1
    j       .Lcopy_payload_words
.Lcopy_payload_tail:
    andi    t2, t2, 3
.Lcopy_payload_bytes:
    beqz    t2, .Lcopy_payload_done
    lbu     t3, 0(t0)
    sb      t3, 0(t1)
    addi    t0, t0, 1
    addi    t1, t1, 1
    addi    t2, t2, -1
    j       .Lcopy_payload_bytes
.Lcopy_payload_done:
    lla     a0, msg_payload_done
    jal     ra, reloc_puts

    li_addr t0, DTB_SRC
    li_addr t1, DTB_DEST
    li_addr t2, DTB_SIZE

    srli    t4, t2, 2
.Lcopy_dtb_words:
    beqz    t4, .Lcopy_dtb_tail
    lw      t3, 0(t0)
    sw      t3, 0(t1)
    addi    t0, t0, 4
    addi    t1, t1, 4
    addi    t4, t4, -1
    j       .Lcopy_dtb_words
.Lcopy_dtb_tail:
    andi    t2, t2, 3
.Lcopy_dtb_bytes:
    beqz    t2, .Lcopy_dtb_done
    lbu     t3, 0(t0)
    sb      t3, 0(t1)
    addi    t0, t0, 1
    addi    t1, t1, 1
    addi    t2, t2, -1
    j       .Lcopy_dtb_bytes
.Lcopy_dtb_done:
    lla     a0, msg_jump_opensbi
    jal     ra, reloc_puts

    fence   rw, rw
    fence.i
    li      a0, 0
    li_addr a1, DTB_DEST
    li_addr t0, MAIN_RAM
    jr      t0

reloc_puts:
    li_addr t0, UART_RXTX
    li_addr t1, UART_TXFULL
.Lreloc_puts_loop:
    lbu     t2, 0(a0)
    beqz    t2, .Lreloc_puts_done
.Lreloc_puts_wait:
    lw      t3, 0(t1)
    bnez    t3, .Lreloc_puts_wait
    sw      t2, 0(t0)
    addi    a0, a0, 1
    j       .Lreloc_puts_loop
.Lreloc_puts_done:
    ret

msg_payload_copy:
    .asciz "stage0: copy payload\n"
msg_payload_done:
    .asciz "stage0: payload copied\n"
msg_jump_opensbi:
    .asciz "stage0: jumping to OpenSBI\n"

    .align 2
_reloc_end:

.section .rodata, "a"
msg_boot:
    .asciz "Raptor KU15P Linux stage0: loading OpenSBI payload\n"
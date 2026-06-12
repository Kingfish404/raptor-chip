# Minimal boot firmware for Raptor LiteX SoC
#
# When main_ram has a payload (first word != 0), jump to it.
# Otherwise print a banner and loop.
#
# The compiled DTB (litex-soc.dtb) is embedded in .rodata and its
# address is passed in a1 to the payload (OpenSBI / bare-metal).
#
# Memory map:
#   ROM:          0x20000000
#   SRAM:         0x0f000000 (8KB)
#   main_ram:     0x80000000 (8MB)
#   UART RXTX:    0xf0001800
#   UART TXFULL:  0xf0001804

.equ MAIN_RAM,  0x80000000
.equ UART_RXTX, 0xf0001800
.equ UART_TXFULL, 0xf0001804
.equ DTB_DEST,  0x80700000   # DTB copy destination near top of main_ram

.macro li_addr reg, val
    li      \reg, (((\val) >> 24) & 0xff)
    slli    \reg, \reg, 8
    ori     \reg, \reg, (((\val) >> 16) & 0xff)
    slli    \reg, \reg, 8
    ori     \reg, \reg, (((\val) >> 8) & 0xff)
    slli    \reg, \reg, 8
    ori     \reg, \reg, ((\val) & 0xff)
.endm

.section .text
.global _start
_start:
    # Set up stack pointer (end of SRAM at 0x0f002000)
    li_addr sp, 0x0f002000

    # Print an early boot banner BEFORE touching main_ram. main_ram is a
    # bus slave that only answers if the SoC actually instantiated it; probing
    # it first (as the old code did) makes `make sim` (no payload) appear to
    # produce zero output if that first load stalls. Printing here guarantees
    # visible UART output the instant the CPU starts fetching from ROM.
    la      a0, msg_boot
    jal     ra, puts

    # Check if main_ram has a payload (first word != 0).
    li_addr t0, MAIN_RAM
    lw      t1, 0(t0)
    beqz    t1, .Lno_payload

    # Print boot message then jump to payload.
    la      a0, msg_jump
    jal     ra, puts

    # Copy DTB from ROM to main_ram so payload reads from fast cached memory.
    # _dtb_end marks the exact end of the embedded DTB.
    la      t0, _dtb            # source (ROM)
    la      t4, _dtb_end        # end of DTB
    li_addr t1, DTB_DEST        # destination (main_ram)
.Lcopy_dtb:
    lw      t3, 0(t0)
    sw      t3, 0(t1)
    addi    t0, t0, 4
    addi    t1, t1, 4
    blt     t0, t4, .Lcopy_dtb

    li      a0, 0               # a0 = hartid (required by OpenSBI/Linux)
    li_addr a1, DTB_DEST        # a1 = DTB address (main_ram copy)
    li_addr t0, MAIN_RAM
    jr      t0

.Lno_payload:
    # No payload — print banner and halt.
    la      a0, msg_banner
    jal     ra, puts
1:  wfi
    j       1b

# puts: print null-terminated string at a0
puts:
    li_addr t0, UART_RXTX
    li_addr t1, UART_TXFULL
.Lputs_loop:
    lbu     t2, 0(a0)           # Load byte
    beqz    t2, .Lputs_done     # Null terminator?
.Lputs_wait:
    lw      t3, 0(t1)           # Read TXFULL
    bnez    t3, .Lputs_wait     # Wait if full
    sw      t2, 0(t0)           # Write byte to UART
    addi    a0, a0, 1
    j       .Lputs_loop
.Lputs_done:
    ret

.section .rodata
msg_boot:
    .asciz "Raptor LiteX SoC — boot\n"
msg_banner:
    .asciz "Raptor LiteX SoC — no payload in main_ram.\n"
msg_jump:
    .asciz "Raptor LiteX SoC — jumping to 0x80000000\n"

    .balign 4
_dtb:
    .incbin "litex-soc.dtb"
_dtb_end:

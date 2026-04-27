# Minimal C-runtime startup for Raptor Tang Mega 138K Pro bring-up.
#
# Memory map (must agree with link.ld and the LiteX FPGA SoC):
#   ROM   : 0x20000000  (32 KB, integrated_rom)
#   SRAM  : 0x0f000000  (8 KB,  integrated_sram — stack + .data + .bss)
#   UART  : 0xf0001800  (LiteX liteuart CSR base)
#
# Reset-vector code path:
#   1. Set up sp at the top of SRAM.
#   2. Zero .bss (C runtime contract).
#   3. Copy .data from ROM (LMA) to SRAM (VMA).
#   4. Call C main(); halt with `wfi` if it ever returns.

.section .text.init, "ax"
.global _start
_start:
    # Install trap vector FIRST so any fault from this point onward is
    # caught and dumped via UART (instead of CPU silently going dark).
    # Direct mode (mode bits = 00); 4-byte aligned by .align 2 below.
    la      t0, _trap_entry
    csrw    mtvec, t0
    # Keep MIE off — we only want synchronous exceptions, no IRQs.
    csrw    mie, zero
    li      t0, 0x8
    csrc    mstatus, t0

    # Stack pointer at top of SRAM (linker symbol).
    la      sp, _stack_top

    # Clear .bss [_sbss, _ebss).
    la      t0, _sbss
    la      t1, _ebss
.Lbss_loop:
    bgeu    t0, t1, .Lbss_done
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       .Lbss_loop
.Lbss_done:

    # Copy .data: ROM [_sidata, _sidata + (_edata - _sdata)) -> SRAM [_sdata, _edata).
    la      t0, _sdata
    la      t1, _edata
    la      t2, _sidata
.Ldata_loop:
    bgeu    t0, t1, .Ldata_done
    lw      t3, 0(t2)
    sw      t3, 0(t0)
    addi    t0, t0, 4
    addi    t2, t2, 4
    j       .Ldata_loop
.Ldata_done:

    # Hand off to C main(). Hartid in a0 follows the RISC-V ABI convention,
    # though the FPGA SoC is single-hart so it is always 0.
    li      a0, 0
    call    main

    # main() should not return on FPGA bring-up; halt if it does.
.Lhalt:
    wfi
    j       .Lhalt

# ============================================================================
# Trap entry — naked, mtvec direct mode.
# Captures mcause/mepc/mtval/old_sp, switches to a dedicated trap stack
# (separate from the main stack so a corrupt sp can't cascade), and calls
# C trap_dump(). Returns are intentionally a busy loop: we want the FPGA to
# stop here so the host can read the dump.
# ============================================================================
.section .text, "ax"
.align 2
.global _trap_entry
_trap_entry:
    # Switch to trap stack so we don't depend on the (possibly corrupt) main sp.
    la      sp, _trap_stack_top
    # ABI args for trap_dump(uint32_t mcause, uint32_t mepc, uint32_t mtval, uint32_t old_sp)
    csrr    a0, mcause
    csrr    a1, mepc
    csrr    a2, mtval
    # Recover the pre-trap sp via mscratch (we never wrote it, so this is
    # actually 0; instead just hand the current sp through). For diagnostic
    # purposes the caller's sp is more useful — but to recover it we'd need
    # mscratch swap. Skip for now and pass 0; mepc is the diagnostic gold.
    li      a3, 0
    call    trap_dump
.Ltrap_halt:
    wfi
    j       .Ltrap_halt

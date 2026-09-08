.global main
.global isr
.global _start

_start:
  j crt_init
  nop
  nop
  nop
  nop
  nop
  nop
  nop

.global trap_entry
trap_entry:
  sw x1,  - 1*4(sp)
  sw x5,  - 2*4(sp)
  sw x6,  - 3*4(sp)
  sw x7,  - 4*4(sp)
  sw x10, - 5*4(sp)
  sw x11, - 6*4(sp)
  sw x12, - 7*4(sp)
  sw x13, - 8*4(sp)
  sw x14, - 9*4(sp)
  sw x15, -10*4(sp)
  sw x16, -11*4(sp)
  sw x17, -12*4(sp)
  sw x28, -13*4(sp)
  sw x29, -14*4(sp)
  sw x30, -15*4(sp)
  sw x31, -16*4(sp)
  addi sp, sp, -16*4
  // Distinguish synchronous exceptions (mcause MSB=0) from interrupts.
  //
  // Interrupts fall through to the C-level isr() handler (PLIC claim loop).
  // Exceptions are routed to a recovery path that records mepc/mcause/mtval
  // into rapt_last_exc[] and advances mepc past the offending instruction so
  // a stray BIOS access (e.g. `mem_read 0xdeadbeef`) does not deadlock the
  // BIOS prompt. Recovery is "best effort": the offending load/store/fetch
  // is skipped (mepc += 2 for compressed, +4 otherwise) and execution
  // resumes; the BIOS command loop will print the next prompt.
  csrr a0, mcause
  bltz a0, 1f                    // MSB set => interrupt path
  // ---- exception recovery (no C call: keep BIOS link footprint minimal) ----
  csrr a1, mepc
  csrr a2, mtval
  // Stash {mcause, mepc, mtval, mtval} into the global record. Layout must
  // match `struct rapt_last_exc` declared in system.h.
  la   a3, rapt_last_exc
  sw   a0, 0(a3)
  sw   a1, 4(a3)
  sw   a2, 8(a3)
  lw   a4, 12(a3)
  addi a4, a4, 1
  sw   a4, 12(a3)                // ++rapt_last_exc.count
  // Advance mepc: try to detect a compressed instruction (low 2 bits != 11).
  // Reading the instruction from mepc is safe in practice because mepc
  // points to a fetched instruction, so its page must be readable. Use a
  // halfword load to avoid faulting on cross-page boundaries.
  lhu  a5, 0(a1)
  andi a6, a5, 3
  li   a7, 3
  beq  a6, a7, 3f
  addi a1, a1, 2                 // compressed: 2 bytes
  j    4f
3:
  addi a1, a1, 4                 // 32-bit instruction
4:
  csrw mepc, a1
  j    2f
1:
  call isr
2:
  lw x1,  15*4(sp)
  lw x5,  14*4(sp)
  lw x6,  13*4(sp)
  lw x7,  12*4(sp)
  lw x10, 11*4(sp)
  lw x11, 10*4(sp)
  lw x12,  9*4(sp)
  lw x13,  8*4(sp)
  lw x14,  7*4(sp)
  lw x15,  6*4(sp)
  lw x16,  5*4(sp)
  lw x17,  4*4(sp)
  lw x28,  3*4(sp)
  lw x29,  2*4(sp)
  lw x30,  1*4(sp)
  lw x31,  0*4(sp)
  addi sp, sp, 16*4
  mret
  .text

crt_init:
  la sp, _fstack
  la a0, trap_entry
  csrw mtvec, a0

data_init:
  la a0, _fdata
  la a1, _edata
  la a2, _fdata_rom
data_loop:
  beq a0, a1, data_done
  lw a3, 0(a2)
  sw a3, 0(a0)
  add a0, a0, 4
  add a2, a2, 4
  j data_loop
data_done:

bss_init:
  la a0, _fbss
  la a1, _ebss
bss_loop:
  beq a0, a1, bss_done
  sw zero, 0(a0)
  add a0, a0, 4
  j bss_loop
bss_done:

  li a0, 0x800     // Enable external interrupt sources (mie.MEIE)
  csrw mie, a0
  csrw mscratch, zero  // Clear irq.h's software irq-mask shadow

  call main
infinit_loop:
  j infinit_loop

// Synchronous-exception capture record. Updated by trap_entry's
// exception fast path. Layout: { mcause, mepc, mtval, count }, all XLEN
// (4 bytes on RV32). bss_init zeroes this at boot; readers can latch
// rapt_last_exc.count, perform a probing access, and compare to detect
// whether a trap happened on the probed instruction.
  .section .bss
  .globl rapt_last_exc
  .align 2
  .type rapt_last_exc, @object
  .size rapt_last_exc, 16
rapt_last_exc:
  .skip 16
  .text

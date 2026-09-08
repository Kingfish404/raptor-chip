/* Full-width state checks for the half-width PLIC rejection cases. */
.macro half_plic_seed
  la t0, half_plic_source
  fld f0, 0(t0)
  la t0, half_plic_dest
  fld f2, 0(t0)
  li t0, 0x43
  csrw fcsr, t0
.endm
.macro half_plic_check
  csrr t0, fcsr
  li t1, 0x43
  bne t0, t1, fail
  la t0, half_plic_saved
  fsd f0, 0(t0)
  fsd f2, 8(t0)
  la t1, half_plic_source
  lw t2, 0(t1)
  lw t3, 0(t0)
  bne t2, t3, fail
  lw t2, 4(t1)
  lw t3, 4(t0)
  bne t2, t3, fail
  la t1, half_plic_dest
  lw t2, 0(t1)
  lw t3, 8(t0)
  bne t2, t3, fail
  lw t2, 4(t1)
  lw t3, 12(t0)
  bne t2, t3, fail
.endm
.pushsection .data
.balign 8
half_plic_source: .dword 0xffffffffffff0000
half_plic_dest: .dword 0x0123456789abcdef
half_plic_saved: .zero 16
.popsection

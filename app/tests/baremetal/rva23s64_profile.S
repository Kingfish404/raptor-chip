/* Comprehensive RV64 RVA23S64 architectural regression:
 *   - Svnapot (VS-stage and G-stage 64 KiB leaves)
 *   - Sscofpmf (scountovf read-only zero and LCOFI bit 13)
 *   - Smstateen / Ssstateen (mstateen/hstateen/sstateen SE0 & ENVCFG gating)
 *   - Smnpm / Ssnpm (M, HS, VS, VU, and HLV/HSV pointer masking)
 *   - Sha + H two-stage Sv39 x Sv39x4 translation, Svpbmt override,
 *     all 13 HLV/HLVX/HSV instructions, cross-page preflight, implicit VS PTW
 *     htinst=0x3000, CMO in V=1, AMO in V=1, MPRV+MPV, and RVV vle8ff.v GPF.
 */
#if __riscv_xlen != 64
#error RVA23S64 requires RV64
#endif
#include "raptor_platform.h"

.option norvc
.option norelax
.section .text
.globl _start

#define CSR_SENVCFG   0x10a
#define CSR_SSTATEEN0 0x10c
#define CSR_VSSTATUS  0x200
#define CSR_VSTVEC    0x205
#define CSR_VSTIMECMP 0x24d
#define CSR_VSATP     0x280
#define CSR_MENVCFG   0x30a
#define CSR_MSTATEEN0 0x30c
#define CSR_MTINST    0x34a
#define CSR_MTVAL2    0x34b
#define CSR_HSTATUS   0x600
#define CSR_HEDELEG   0x602
#define CSR_HIDELEG   0x603
#define CSR_HTIMEDELTA 0x605
#define CSR_HCOUNTEREN 0x606
#define CSR_HENVCFG   0x60a
#define CSR_HSTATEEN0 0x60c
#define CSR_HTVAL     0x643
#define CSR_HTINST    0x64a
#define CSR_HGATP     0x680
#define CSR_SCOUNTOVF 0xda0

.macro hfence_vvma
  .word 0x22000073
.endm
.macro hinval_vvma
  .word 0x26000073
.endm
.macro hfence_gvma
  .word 0x62000073
.endm
.macro hinval_gvma
  .word 0x66000073
.endm
.macro hlv_b_a2_a0
  .word ((0x600 << 20) | (10 << 15) | (4 << 12) | (12 << 7) | 0x73)
.endm
.macro hlv_bu_a2_a0
  .word ((0x601 << 20) | (10 << 15) | (4 << 12) | (12 << 7) | 0x73)
.endm
.macro hlv_h_a2_a0
  .word ((0x640 << 20) | (10 << 15) | (4 << 12) | (12 << 7) | 0x73)
.endm
.macro hlv_hu_a2_a0
  .word ((0x641 << 20) | (10 << 15) | (4 << 12) | (12 << 7) | 0x73)
.endm
.macro hlv_w_a2_a0
  .word ((0x680 << 20) | (10 << 15) | (4 << 12) | (12 << 7) | 0x73)
.endm
.macro hlv_wu_a2_a0
  .word ((0x681 << 20) | (10 << 15) | (4 << 12) | (12 << 7) | 0x73)
.endm
.macro hlv_d_a2_a0
  .word ((0x6c0 << 20) | (10 << 15) | (4 << 12) | (12 << 7) | 0x73)
.endm
.macro hlvx_hu_a2_a0
  .word ((0x643 << 20) | (10 << 15) | (4 << 12) | (12 << 7) | 0x73)
.endm
.macro hlvx_wu_a2_a0
  .word ((0x683 << 20) | (10 << 15) | (4 << 12) | (12 << 7) | 0x73)
.endm
.macro hsv_b_a1_a0
  .word ((0x31 << 25) | (11 << 20) | (10 << 15) | (4 << 12) | 0x73)
.endm
.macro hsv_h_a1_a0
  .word ((0x33 << 25) | (11 << 20) | (10 << 15) | (4 << 12) | 0x73)
.endm
.macro hsv_w_a1_a0
  .word ((0x35 << 25) | (11 << 20) | (10 << 15) | (4 << 12) | 0x73)
.endm
.macro hsv_d_a1_a0
  .word ((0x37 << 25) | (11 << 20) | (10 << 15) | (4 << 12) | 0x73)
.endm
.macro cbo_clean_a0
  .word ((0x001 << 20) | (10 << 15) | (2 << 12) | 0x0f)
.endm
.macro cbo_zero_a0
  .word ((0x004 << 20) | (10 << 15) | (2 << 12) | 0x0f)
.endm
.macro vsetivli_t0_8_e8
  .word ((3 << 30) | (0xc0 << 20) | (8 << 15) | (7 << 12) | (5 << 7) | 0x57)
.endm
.macro vle8ff_v8_a0
  .word ((1 << 25) | (16 << 20) | (10 << 15) | (8 << 7) | 0x07)
.endm

/* Expect a trap to M-mode with cause=s8, mtval=s7, mtval2=s6, mtinst=s5,
 * and (mstatus & (3 << 38)) == s4. */
.macro expect_m_trap insn:vararg
  li s9, 1
  la s10, 991f
990:
  \insn
  j fail
991:
  bnez s9, fail
.endm

_start:
  li s11, 1
  la t0, m_trap
  csrw mtvec, t0
  csrw mie, zero
  csrw medeleg, zero
  csrw mideleg, zero

  /* Verify misa.B, misa.H, misa.S, misa.U, misa.V */
  csrr t0, misa
  li t1, (1 << 1) | (1 << 7) | (1 << 18) | (1 << 20) | (1 << 21)
  and t2, t0, t1
  bne t2, t1, fail

  /* PMP open for all physical memory */
  li t0, -1
  csrw pmpaddr0, t0
  li t0, 0x0f
  csrw pmpcfg0, t0

  /* Stage 1a: Sscofpmf scountovf RO-zero & LCOFI bit 13 */
  csrr t0, CSR_SCOUNTOVF
  bnez t0, fail
  li s8, 2
  li s7, ((CSR_SCOUNTOVF << 20) | (5 << 15) | (1 << 12) | 0x73)
  li s6, 0
  li s5, 0
  li s4, 0
  expect_m_trap csrw CSR_SCOUNTOVF, t0
  li t0, 0x2000
  csrs mip, t0
  csrr t1, mip
  and t1, t1, t0
  bne t1, t0, fail
  csrc mip, t0

  /* Stage 1b: Smstateen0..3 & Smnpm/Ssnpm WARL */
  li s11, 2
  li t0, -1
  csrw CSR_MSTATEEN0, t0
  csrr t1, CSR_MSTATEEN0
  li t2, (3 << 62)
  bne t1, t2, fail
  li t0, (1 << 32)          /* Reserved PMM=1 -> 0 in menvcfg/henvcfg/hstatus */
  csrw CSR_MENVCFG, t0
  csrr t1, CSR_MENVCFG
  bnez t1, fail
  li t0, (2 << 32) | (3 << 62) | 0xf0
  csrw CSR_MENVCFG, t0
  csrr t1, CSR_MENVCFG
  bne t1, t0, fail
  csrw CSR_MENVCFG, zero

  /* Stage 2: Build Sv39 (VS) x Sv39x4 (G) multi-level + Svnapot + Svpbmt tables */
  li s11, 3
  /* Initialize test data pages */
  la t0, page_a
  li t1, 0x8877665544332211
  sd t1, 0(t0)
  li t1, 0xffffffff80008080
  sd t1, 8(t0)
  li t2, 0xff8
  add t2, t0, t2
  li t1, 0x1122334455667788
  sd t1, 0(t2)
  li t1, 0xdeadbeefcafebabe
  la t2, page_b
  sd t1, 0(t2)
  li t1, 0x55aa55aa55aa55aa
  sd t1, 0x90(t0)
  sd t1, 0x98(t0)

  la t0, page_c
  li t1, 0x6464646464646464
  sd t1, 0x458(t0)

  la t0, g_napot_pool
  li t2, 0x5128
  add t0, t0, t2
  li t1, 0x9988776655443322
  sd t1, 0(t0)

  /* Populate execute-only page with: li a0, 0x5a; sret / ret */
  la t0, exec_page
  li t1, 0x05a00513         /* addi a0, zero, 0x5a */
  sw t1, 0(t0)
  li t1, 0x00008067         /* ret (jalr x0, ra, 0) */
  sw t1, 4(t0)

  la t0, high_gpa_page
  li t1, 0x07700513         /* addi a0, zero, 0x77 */
  sw t1, 0(t0)
  li t1, 0x00008067         /* ret */
  sw t1, 4(t0)
  li t1, 0x4141414142424242
  sd t1, 8(t0)

  /* G-stage root (16 KiB aligned, Sv39x4):
   *   vpn2=2 (GPA 0x80000000..0xbfffffff): 1 GiB identity leaf (RWX+U+A+D = 0xdf)
   *   vpn2=0 (GPA 0x00000000..0x3fffffff): -> g_l1
   *   vpn2=4 (GPA 0x100_0000_0000):        -> g_high_l1 (tests bit 40 = 1!)
   */
  la s0, g_root
  li t1, ((0x80000000 >> 12) << 10) | 0xdf
  sd t1, 16(s0)

  la t0, g_l1
  srli t1, t0, 12
  slli t1, t1, 10
  ori t1, t1, 0x01
  sd t1, 0(s0)

  /* g_l1[256] (GPA 0x20000000..0x201fffff) -> g_l0 */
  la t2, g_l0
  srli t1, t2, 12
  slli t1, t1, 10
  ori t1, t1, 0x01
  li t3, (256 * 8)
  add t3, t0, t3
  sd t1, 0(t3)

  /* g_high_l1 -> g_high_l0 -> high_gpa_page at GPA 0x100_0000_0000 (vpn2=1024)
   * and GPA 0x48_0000_0000 (vpn2=288, above Sv39 256 GiB limit, within PC40) */
  la t0, g_high_l1
  srli t1, t0, 12
  slli t1, t1, 10
  ori t1, t1, 0x01
  li t3, (1024 * 8)
  add t3, s0, t3
  sd t1, 0(t3)
  li t3, (288 * 8)
  add t3, s0, t3
  sd t1, 0(t3)
  la t2, g_high_l0
  srli t1, t2, 12
  slli t1, t1, 10
  ori t1, t1, 0x01
  sd t1, 0(t0)
  la t0, high_gpa_page
  srli t1, t0, 12
  slli t1, t1, 10
  ori t1, t1, 0xdf
  sd t1, 0(t2)

  /* Populate g_l0:
   *   [0] GPA 0x20000000 -> page_a (RWX+U+A+D = 0xdf)
   *   [1] GPA 0x20001000 -> page_b (RWX+U+A+D = 0xdf)
   *   [2] GPA 0x20002000 -> exec_page (X-only+U+A = 0x59)
   *   [3] GPA 0x20003000 -> pbmt_page_a (G PBMT=IO(2), RW+U+A+D)
   *   [4] GPA 0x20004000 -> pbmt_page_b (G PBMT=IO(2), RW+U+A+D)
   *   [14] GPA 0x2000e000 -> vs_l1 (RW+U+A+D = 0xd7)
   *   [15] GPA 0x2000f000 -> vs_l0 (RW+U+A+D = 0xd7)
   *   [19] GPA 0x20013000 -> page_c (4 KiB G leaf under 64 KiB VS NAPOT!)
   *   [32..47] GPA 0x20020000..0x2002ffff -> g_napot_pool (64 KiB G Svnapot!)
   */
  la s1, g_l0
  la t0, page_a
  srli t1, t0, 12
  slli t1, t1, 10
  ori t1, t1, 0xdf
  sd t1, 0(s1)

  la t0, page_b
  srli t1, t0, 12
  slli t1, t1, 10
  ori t1, t1, 0xdf
  sd t1, 8(s1)

  la t0, exec_page
  srli t1, t0, 12
  slli t1, t1, 10
  ori t1, t1, 0x59          /* V=1, R=0, W=0, X=1, U=1, A=1 */
  sd t1, 16(s1)

  li t2, (2 << 61)          /* PBMT = IO (2) */
  la t0, pbmt_page_a
  srli t1, t0, 12
  slli t1, t1, 10
  ori t1, t1, 0xd7
  or t1, t1, t2
  sd t1, 24(s1)

  la t0, pbmt_page_b
  srli t1, t0, 12
  slli t1, t1, 10
  ori t1, t1, 0xd7
  or t1, t1, t2
  sd t1, 32(s1)

  la t0, vs_l1
  srli t1, t0, 12
  slli t1, t1, 10
  ori t1, t1, 0xd7
  sd t1, (14 * 8)(s1)

  la t0, vs_l0
  srli t1, t0, 12
  slli t1, t1, 10
  ori t1, t1, 0xd7
  sd t1, (15 * 8)(s1)

  la t0, page_c
  srli t1, t0, 12
  slli t1, t1, 10
  ori t1, t1, 0xd7
  sd t1, (19 * 8)(s1)

  /* G-stage 64 KiB Svnapot leaf at indices 32..47 (GPA 0x20020000..0x2002ffff) */
  la t0, g_napot_pool
  srli t1, t0, 16
  slli t1, t1, 4
  ori t1, t1, 8             /* PPN[3:0] = 4'b1000 */
  slli t1, t1, 10
  ori t1, t1, 0xd7
  li t2, (1 << 63)
  or t1, t1, t2
  li t3, 32
1:
  slli t4, t3, 3
  add t4, s1, t4
  sd t1, 0(t4)
  addi t3, t3, 1
  li t4, 48
  blt t3, t4, 1b

  /* Populate VS-stage tables:
   *   vs_root[2]: 1 GiB identity leaf at 0x80000000 (RWX+U+A+D = 0xdf)
   *   vs_root[1]: VA 0x40000000..0x7fffffff -> GPA 0x2000e000 (vs_l1)
   *   vs_l1[0]:   VA 0x40000000..0x401fffff -> GPA 0x2000f000 (vs_l0)
   *   vs_l0[0]:   VA 0x40000000 -> GPA 0x20000000 (RWX+U+A+D = 0xdf)
   *   vs_l0[1]:   VA 0x40001000 -> GPA 0x20001000 (RWX+U+A+D = 0xdf)
   *   vs_l0[2]:   VA 0x40002000 -> GPA 0x20002000 (X-only+U+A = 0x59)
   *   vs_l0[3]:   VA 0x40003000 -> GPA 0x20003000 (VS PBMT=NC(1), RW+U+A+D)
   *   vs_l0[4]:   VA 0x40004000 -> GPA 0x20004000 (VS PBMT=PMA(0), RW+U+A+D)
   *   vs_l0[5]:   VA 0x40005000 -> GPA 0x20000000 (VS supervisor-only U=0, 0xcf)
   *   vs_l0[16..31]: VA 0x40010000..0x4001ffff -> 64 KiB VS Svnapot GPA 0x20010000
   *   vs_l0[32]:  VA 0x40020000 -> GPA 0x20025000 (4 KiB VS -> 64 KiB G NAPOT+5!)
   */
  la s2, vs_root
  li t1, ((0x80000000 >> 12) << 10) | 0xcf /* VS supervisor RWX (U=0) */
  sd t1, 16(s2)
  li t1, ((0x2000e000 >> 12) << 10) | 0x01
  sd t1, 8(s2)

  la t0, vs_l1
  li t1, ((0x2000f000 >> 12) << 10) | 0x01
  sd t1, 0(t0)

  la s3, vs_l0
  li t1, ((0x20000000 >> 12) << 10) | 0xdf
  sd t1, 0(s3)
  li t1, ((0x20001000 >> 12) << 10) | 0xdf
  sd t1, 8(s3)
  li t1, ((0x20002000 >> 12) << 10) | 0x49 /* VS X-only supervisor (U=0) */
  sd t1, 16(s3)
  li t2, (1 << 61)          /* VS PBMT = NC (1) */
  li t1, ((0x20003000 >> 12) << 10) | 0xd7
  or t1, t1, t2
  sd t1, 24(s3)
  li t1, ((0x20004000 >> 12) << 10) | 0xd7
  sd t1, 32(s3)
  li t1, ((0x20000000 >> 12) << 10) | 0xcf /* U=0 supervisor-only */
  sd t1, 40(s3)

  /* VS 64 KiB Svnapot leaf at indices 16..31 -> GPA 0x20010000 (PPN=0x20018) */
  li t1, (0x20018 << 10) | 0xd7
  li t2, (1 << 63)
  or t1, t1, t2
  li t3, 16
2:
  slli t4, t3, 3
  add t4, s3, t4
  sd t1, 0(t4)
  addi t3, t3, 1
  li t4, 32
  blt t3, t4, 2b

  /* VS 4 KiB leaf at index 32 -> GPA 0x20025000 */
  li t1, ((0x20025000 >> 12) << 10) | 0xd7
  sd t1, (32 * 8)(s3)

  /* Program hgatp (VMID=3) and vsatp (ASID=5), enable menvcfg/henvcfg PBMTE+STCE+CMO */
  srli t0, s0, 12
  li t1, (8 << 60) | (3 << 44)
  or t0, t0, t1
  csrw CSR_HGATP, t0

  srli t0, s2, 12
  li t1, (8 << 60) | (5 << 44)
  or t0, t0, t1
  csrw CSR_VSATP, t0

  li t0, (3 << 62) | 0xf0
  csrw CSR_MENVCFG, t0
  csrw CSR_HENVCFG, t0
  li t0, (3 << 62)
  csrw CSR_MSTATEEN0, t0
  csrw CSR_HSTATEEN0, t0
  li t0, 7
  csrw mcounteren, t0
  csrw CSR_HCOUNTEREN, t0
  csrw scounteren, t0
  li t0, 0x6600             /* FS=Dirty, VS=Dirty */
  csrs mstatus, t0
  li t0, 0x46600            /* vsstatus: SUM=1, FS=Dirty, VS=Dirty */
  csrw CSR_VSSTATUS, t0
  hfence_gvma
  hfence_vvma
  fence.i

  /* Stage 3: All 13 HLV/HLVX/HSV instructions & corner cases (from M-mode) */
  li s11, 4
  li t0, 0x100              /* hstatus.SPVP = 1 (VS) */
  csrw CSR_HSTATUS, t0

  /* Test signed/unsigned subword HLV on 0xffffffff80008080 at VA 0x40000008 */
  li a0, 0x40000008
  hlv_b_a2_a0
  li t0, -128
  bne a2, t0, fail
  hlv_bu_a2_a0
  li t0, 0x80
  bne a2, t0, fail
  hlv_h_a2_a0
  li t0, -32640             /* 0xffffffffffff8080 */
  bne a2, t0, fail
  hlv_hu_a2_a0
  li t0, 0x8080
  bne a2, t0, fail
  hlv_w_a2_a0
  li t0, 0xffffffff80008080
  bne a2, t0, fail
  hlv_wu_a2_a0
  li t0, 0x80008080
  bne a2, t0, fail
  hlv_d_a2_a0
  li t0, 0xffffffff80008080
  bne a2, t0, fail

  /* Test HSV.B / HSV.H / HSV.W / HSV.D + HLV.D readback at VA 0x40000020 */
  li s11, 5
  li a0, 0x40000020
  li a1, -1
  hsv_d_a1_a0
  li a1, 0x12
  hsv_b_a1_a0
  addi a0, a0, 2
  li a1, 0x3456
  hsv_h_a1_a0
  addi a0, a0, 2
  li a1, 0x789abcde
  hsv_w_a1_a0
  li a0, 0x40000020
  hlv_d_a2_a0
  li t0, 0x789abcde3456ff12
  bne a2, t0, fail

  /* Test Svnapot 64K VS x 4K G (0x40013458) and 4K VS x 64K G (0x40020128) */
  li s11, 6
  li a0, 0x40013458
  hlv_d_a2_a0
  li t0, 0x6464646464646464
  bne a2, t0, fail
  li a0, 0x40020128
  hlv_d_a2_a0
  li t0, 0x9988776655443322
  bne a2, t0, fail

  /* Test HLVX.HU / HLVX.WU on X-only page (VA 0x40002000) with MXR=0 */
  li s11, 7
  li a0, 0x40002000
  hlvx_hu_a2_a0
  li t0, 0x0513
  bne a2, t0, fail
  hlvx_wu_a2_a0
  li t0, 0x05a00513
  bne a2, t0, fail
  /* Normal HLV.WU on X-only page must raise LOAD_PAGE_FAULT (13) with GVA=1 */
  li s8, 13
  li s7, 0x40002000
  li s6, 0
  li s5, 0
  li s4, (1 << 38)          /* mstatus.GVA = 1, MPV = 0 */
  expect_m_trap hlv_wu_a2_a0

  /* Test SPVP=0 (VU) vs SPVP=1 (VS) on U=0 page VA 0x40005000 */
  li s11, 8
  li a0, 0x40005000
  hlv_d_a2_a0
  li t0, 0x8877665544332211
  bne a2, t0, fail
  csrw CSR_HSTATUS, zero    /* SPVP = 0 (VU) */
  li s8, 13
  li s7, 0x40005000
  li s6, 0
  li s5, 0
  li s4, (1 << 38)
  expect_m_trap hlv_d_a2_a0
  li t0, 0x100
  csrw CSR_HSTATUS, t0

  /* Test cross-page misaligned HSV.D & HLV.D across VA 0x40000ffc..0x40001003 */
  li s11, 9
  li a0, 0x40000ffc
  li a1, 0x0102030405060708
  hsv_d_a1_a0
  hlv_d_a2_a0
  bne a1, a2, fail

  /* Unmap G-stage page_b (g_l0[1]) + hinval.gvma; cross-page HSV.D must fault
   * on page 2 BEFORE modifying page 1! */
  sd zero, 8(s1)
  hinval_gvma
  li a1, 0xffffffffffffffff
  li s8, 23                 /* STORE_GUEST_PAGE_FAULT */
  li s7, 0x40001000         /* Second page GVA! */
  li s6, (0x20001000 >> 2)  /* Second page GPA >> 2 */
  li s5, 0
  li s4, (1 << 38)
  expect_m_trap hsv_d_a1_a0
  /* Confirm page 1 bytes at 0x40000ffc were NOT overwritten */
  li a0, 0x40000ffc
  hlv_wu_a2_a0
  li t0, 0x05060708
  bne a2, t0, fail
  /* Restore g_l0[1] */
  la t0, page_b
  srli t1, t0, 12
  slli t1, t1, 10
  ori t1, t1, 0xdf
  sd t1, 8(s1)
  hfence_gvma

  /* Test misaligned HLV.W / HSV.W on PBMT=NC (VA 0x40003002 -> misaligned 4/6) */
  li s11, 10
  li a0, 0x40003002
  li s8, 4                  /* LOAD_MISALIGNED */
  li s7, 0x40003002
  li s6, 0
  li s5, 0
  li s4, (1 << 38)
  expect_m_trap hlv_w_a2_a0
  li s8, 6                  /* STORE_MISALIGNED */
  expect_m_trap hsv_w_a1_a0

  /* Test HLV/HSV pointer masking (SPVP=1 henvcfg.PMM, SPVP=0 senvcfg.PMM, U+HU HUPMM) */
  li s11, 11
  li t0, (2 << 32) | (3 << 62) | 0xf0   /* henvcfg.PMM = 2 (PMLEN=7) */
  csrw CSR_HENVCFG, t0
  li a0, (0x5aUL << 57) | 0x40000000
  hlv_d_a2_a0
  li t0, 0x8877665544332211
  bne a2, t0, fail

  /* SPVP=0 in M-mode uses senvcfg.PMM (PMLEN=16) */
  csrw CSR_HSTATUS, zero
  li t0, (3 << 32) | 0xf0
  csrw CSR_SENVCFG, t0
  li a0, (0x1234UL << 48) | 0x40000000
  hlv_d_a2_a0
  li t0, 0x8877665544332211
  bne a2, t0, fail

  /* U-mode with hstatus.HU=1, SPVP=0 uses hstatus.HUPMM (PMLEN=7) */
  li t0, (1 << 9) | (2UL << 48)         /* HU=1, HUPMM=2 */
  csrw CSR_HSTATUS, t0
  csrw CSR_SENVCFG, zero
  la t0, u_hu_entry
  csrw mepc, t0
  li t0, (3 << 11)
  csrc mstatus, t0          /* MPP = U (0), MPV = 0 */
  mret

u_hu_entry:
  li a0, (0x3fUL << 57) | 0x40000000
  hlv_d_a2_a0
  li t0, 0x8877665544332211
  bne a2, t0, u_hu_fail
  ecall
u_hu_fail:
  li a0, -1
  ecall

after_u_hu:
  li s11, 12
  li t0, (3 << 62) | 0xf0
  csrw CSR_HENVCFG, t0
  li t0, 0x100
  csrw CSR_HSTATUS, t0

  /* Stage 4a: Implicit VS PTW G-stage fault -> htinst/mtinst = 0x3000! */
  sd zero, (15 * 8)(s1)     /* Unmap GPA 0x2000f000 (vs_l0) in g_l0 */
  hfence_gvma
  li a0, 0x40000018         /* Nonzero word offset: mtval2 must have VS PTE GPA! */
  li s8, 21
  li s7, 0x40000018
  li s6, (0x2000f000 >> 2)  /* vs_l0[0] PTE GPA >> 2 */
  li s5, 0x3000             /* Implicit VS PTW read! */
  li s4, (1 << 38)
  expect_m_trap hlv_d_a2_a0
  /* Restore g_l0[15] */
  la t0, vs_l0
  srli t1, t0, 12
  slli t1, t1, 10
  ori t1, t1, 0xd7
  sd t1, (15 * 8)(s1)
  hfence_gvma

  /* Stage 4b: VS=Bare x G=Sv39x4 at 1 TiB (bit 40 = 1) & 2 TiB overflow (bit 41 = 1) */
  li s11, 13
  csrw CSR_VSATP, zero
  hfence_vvma
  li a0, (1UL << 40) + 8
  hlv_d_a2_a0
  li t0, 0x4141414142424242
  bne a2, t0, fail

  /* 41-bit GPA overflow: GVA = (1 << 41) | 0x20000018 */
  li a0, (1UL << 41) | 0x20000018
  li s8, 21
  mv s7, a0
  srli s6, a0, 2            /* Full 62-bit vaddr[63:2] in mtval2! */
  li s5, 0
  li s4, (1 << 38)
  expect_m_trap hlv_w_a2_a0

  /* Stage 4c: VS=Bare x G=Bare upper-all-ones alias (0xffffffff_8000xxxx) */
  li s11, 14
  csrw CSR_HGATP, zero
  hfence_gvma
  la t0, page_a
  li t1, 0xffffffff00000000
  or a0, t0, t1
  hlv_d_a2_a0
  li t2, 0x8877665544332211
  bne a2, t2, fail

  /* Restore hgatp and vsatp */
  srli t0, s0, 12
  li t1, (8UL << 60) | (3UL << 44)
  or t0, t0, t1
  csrw CSR_HGATP, t0
  srli t0, s2, 12
  li t1, (8UL << 60) | (5UL << 44)
  or t0, t0, t1
  csrw CSR_VSATP, t0
  hfence_gvma
  hfence_vvma

  /* Stage 5: Enter HS-mode & exercise V=1 (VS/VU) 2-stage execution */
  li s11, 15
  li t0, (1 << 5) | (1 << 8) | (1 << 10) | (1 << 13) | (1 << 15) \
       | (1 << 20) | (1 << 21) | (1 << 22) | (1 << 23)
  csrw medeleg, t0
  la t0, hs_trap
  csrw stvec, t0
  la t0, hs_main
  csrw mepc, t0
  li t0, (3 << 11)
  csrc mstatus, t0
  li t0, (1 << 11)          /* MPP = S, MPV = 0 */
  csrs mstatus, t0
  mret

hs_main:
  /* Enter VS-mode at vs_guest_main */
  li s11, 16
  li t0, 0x80               /* hstatus.SPV = 1 */
  csrw CSR_HSTATUS, t0
  li t0, 0x100              /* sstatus.SPP = 1 (VS) */
  csrs sstatus, t0
  la t0, vs_guest_main
  csrw sepc, t0
  sret

vs_guest_main:
  /* 5a: Svnapot 64K VS x 4K G and 4K VS x 64K G loads in V=1 */
  li t0, 0x40013458
  ld t1, 0(t0)
  li t2, 0x6464646464646464
  bne t1, t2, guest_abort

  li t0, 0x40020128
  ld t1, 0(t0)
  li t2, 0x9988776655443322
  bne t1, t2, guest_abort

  /* 5b: Execute code from X-only 2-stage page (VA 0x40002000 -> a0 = 0x5a) */
  li t0, 0x40002000
  jalr ra, t0, 0
  li t1, 0x5a
  bne a0, t1, guest_abort

  /* 5c: Svpbmt override: VA 0x40003001 (VS=NC overrides G=IO -> misaligned ld OK);
   * VA 0x40004001 (VS=PMA + G=IO -> misaligned ld raises LOAD_ACC_FAULT=5!) */
  li t0, 0x40003000
  li t1, 0x1122334455667788
  sd t1, 0(t0)
  ld t2, 1(t0)
  srli t1, t1, 8
  slli t2, t2, 8
  srli t2, t2, 8
  bne t1, t2, guest_abort

  li s8, 5                  /* LOAD_ACC_FAULT */
  li s7, 0x40004001
  li s6, 0
  li s5, 0
  li s4, 0xc0               /* hstatus.{SPV,GVA} = 1,1 */
  li s9, 1
  li t0, 0x40004001
  ld t2, 0(t0)
  bnez s9, guest_abort

  /* 5d: CMO in V=1 + AMO & cbo.zero G-stage write fault after read TLB warm-up!
   * Ask HS via ecall #1 to:
   *   1) clear henvcfg.CBZE -> verify cbo.zero traps with VIRT_INST (22), GVA=0
   *   2) re-enable henvcfg.CBZE and make g_l0[0] read-only (W=0) */
  li a7, 1
  ecall

  /* Now henvcfg.CBZE == 0: cbo.zero must raise VIRT_INST (22) with GVA=0 */
  li a0, 0x40000094
  li s8, 22
  li s7, ((0x004 << 20) | (10 << 15) | (2 << 12) | 0x0f)
  li s6, 0
  li s5, 0
  li s4, 0x80               /* SPV=1, GVA=0! */
  li s9, 1
  cbo_zero_a0
  bnez s9, guest_abort

  /* Ask HS via ecall #2 to set henvcfg.CBZE=1 and make g_l0[0] read-only */
  li a7, 2
  ecall

  /* Warm DTLB with a load from 0x40000090 (VS=RWX, G=RX read-only!) */
  li t0, 0x40000090
  ld t1, 0(t0)
  li t2, 0x55aa55aa55aa55aa
  bne t1, t2, guest_abort
  /* cbo.clean only needs R permission -> MUST SUCCEED even with G W=0! */
  li a0, 0x40000094
  cbo_clean_a0

  /* cbo.zero on 0x40000094 MUST trap with STORE_GUEST_PAGE_FAULT (23) and
   * preserve low address bits [11:2] in htval = (0x20000094 >> 2)! */
  li a0, 0x40000094
  li s8, 23
  li s7, 0x40000094
  li s6, (0x20000094 >> 2)
  li s5, 0
  li s4, 0xc0
  li s9, 1
  cbo_zero_a0
  bnez s9, guest_abort
  /* Confirm memory at 0x40000090 was NOT zeroed! */
  li t0, 0x40000090
  ld t1, 0(t0)
  li t2, 0x55aa55aa55aa55aa
  bne t1, t2, guest_abort

  /* AMO on read-only G-stage leaf (0x40000000) MUST report STORE_GUEST_PAGE_FAULT (23)! */
  li a0, 0x40000000
  li a1, 1
  li s8, 23
  li s7, 0x40000000
  li s6, (0x20000000 >> 2)
  li s5, 0
  li s4, 0xc0
  li s9, 1
  amoadd.d t3, a1, (a0)
  bnez s9, guest_abort

  /* 5e: RVV fault-only-first (vle8ff.v) in V=1 across G-stage fault boundary!
   * Ask HS via ecall #3 to restore g_l0[0] RWX and unmap g_l0[1] (0x40001000). */
  li a7, 3
  ecall

  /* vle8ff.v starting at 0x40000ffc (4 bytes in page_a, 4 bytes in unmapped page_b):
   * MUST NOT trap, and MUST trim vl from 8 to 4! */
  vsetivli_t0_8_e8
  li t1, 8
  bne t0, t1, guest_abort
  li a0, 0x40000ffc
  vle8ff_v8_a0
  csrr t0, vl
  li t1, 4
  bne t0, t1, guest_abort

  /* vle8ff.v starting at 0x40001000 (elem 0 G-unmapped):
   * MUST trap with LOAD_GUEST_PAGE_FAULT (21), htval=(0x20001000>>2), vl preserved=8! */
  vsetivli_t0_8_e8
  li a0, 0x40001000
  li s8, 21
  li s7, 0x40001000
  li s6, (0x20001000 >> 2)
  li s5, 0
  li s4, 0xc0
  li s9, 1
  vle8ff_v8_a0
  bnez s9, guest_abort
  csrr t0, vl
  li t1, 8
  bne t0, t1, guest_abort

  /* 5f: Ask HS via ecall #4 to switch to VS=Bare x G=Sv39x4 and jump to 1 TiB GVA! */
  li a7, 4
  ecall

vs_bare_1tib:
  /* Data load at 1 TiB (vpn2=1024 in 16 KiB g_root) */
  li t0, (1UL << 40) + 8
  ld t1, 0(t0)
  li t2, 0x4141414142424242
  bne t1, t2, guest_abort
  /* Instruction fetch at 288 GiB (bit 38 = 1, non-canonical in Sv39, valid in Sv39x4) */
  li t0, (288UL << 30)
  jalr ra, t0, 0
  li t1, 0x77
  bne a0, t1, guest_abort

  /* Return cleanly to HS */
  li a7, 99
  ecall

guest_abort:
  li a7, -1
  ecall

hs_after_guest:
  /* Return to M-mode for Stage 6 (M-mode + MPRV=1 + MPV=1) */
  li s11, 20
  li a7, 100
  ecall
  j fail

m_stage6:
  /* Stage 6: M-mode with MPRV=1, MPP=S(1), MPV=1 two-stage data translation! */
  li s11, 21
  srli t0, s2, 12
  li t1, (8UL << 60) | (5UL << 44)
  or t0, t0, t1
  csrw CSR_VSATP, t0
  la t0, page_a
  srli t1, t0, 12
  slli t1, t1, 10
  ori t1, t1, 0xdf
  sd t1, 0(s1)
  sd zero, 8(s1)            /* Keep 0x40001000 G-unmapped */
  hfence_gvma
  hfence_vvma

  li t0, (3 << 11)
  csrc mstatus, t0
  li t0, (1UL << 39) | (1 << 17) | (1 << 11) /* MPV=1, MPRV=1, MPP=S */
  csrs mstatus, t0

  li t0, 0x40000000
  ld t1, 0(t0)
  li t2, 0x8877665544332211
  bne t1, t2, fail

  /* Faulting MPRV+MPV load on 0x40001000 -> mcause=21, mstatus.GVA=1, MPV=0 (trap from M!) */
  li t0, 0x40001000
  li s8, 21
  li s7, 0x40001000
  li s6, (0x20001000 >> 2)
  li s5, 0
  li s4, (1UL << 38)        /* mstatus.GVA = 1, MPV = 0 (since trap came from M) */
  expect_m_trap ld t1, 0(t0)

  li t0, (1UL << 39) | (1 << 17)
  csrc mstatus, t0

  /* ALL STAGES PASSED! */
  li t0, RAPTOR_FINISHER_BASE
  li t1, 0x5555
  sw t1, 0(t0)
1:
  j 1b

/* HS-mode trap handler */
.balign 4
hs_trap:
  csrr t0, scause
  li t1, 10                 /* ECALL from VS */
  beq t0, t1, hs_ecall
  beqz s9, fail
  bne t0, s8, fail
  csrr t0, stval
  bne t0, s7, fail
  csrr t0, CSR_HTVAL
  bne t0, s6, fail
  csrr t0, CSR_HTINST
  bne t0, s5, fail
  csrr t0, CSR_HSTATUS
  andi t0, t0, 0xc0
  bne t0, s4, fail
  li s9, 0
  csrr t0, sepc
  addi t0, t0, 4
  csrw sepc, t0
  sret

hs_ecall:
  bltz a7, fail
  li t0, 1
  beq a7, t0, hs_svc_1
  li t0, 2
  beq a7, t0, hs_svc_2
  li t0, 3
  beq a7, t0, hs_svc_3
  li t0, 4
  beq a7, t0, hs_svc_4
  li t0, 99
  beq a7, t0, hs_svc_done
  j fail

hs_svc_1:
  li t0, 0x80               /* Clear henvcfg.CBZE */
  csrc CSR_HENVCFG, t0
  j hs_svc_ret
hs_svc_2:
  li t0, 0x80
  csrs CSR_HENVCFG, t0
  la t0, page_a
  srli t1, t0, 12
  slli t1, t1, 10
  ori t1, t1, 0x5b          /* R=1, W=0, X=1, U=1, A=1 (read-only G leaf!) */
  sd t1, 0(s1)
  hfence_gvma
  j hs_svc_ret
hs_svc_3:
  la t0, page_a
  srli t1, t0, 12
  slli t1, t1, 10
  ori t1, t1, 0xdf
  sd t1, 0(s1)
  sd zero, 8(s1)
  hfence_gvma
  j hs_svc_ret
hs_svc_4:
  csrw CSR_VSATP, zero
  hfence_vvma
  la t0, vs_bare_1tib
  csrw sepc, t0
  sret
hs_svc_done:
  li t0, 0x80
  csrc CSR_HSTATUS, t0
  la t0, hs_after_guest
  csrw sepc, t0
  sret
hs_svc_ret:
  csrr t0, sepc
  addi t0, t0, 4
  csrw sepc, t0
  sret

/* M-mode trap handler */
.balign 4
m_trap:
  csrr t0, mcause
  li t1, 8                  /* ECALL from U-mode (u_hu_entry) */
  beq t0, t1, m_from_u_hu
  li t1, 9                  /* ECALL from HS-mode (hs_after_guest) */
  beq t0, t1, m_from_hs
  beqz s9, fail
  bne t0, s8, fail
  csrr t0, mtval
  bne t0, s7, fail
  csrr t0, CSR_MTVAL2
  bne t0, s6, fail
  csrr t0, CSR_MTINST
  bne t0, s5, fail
  csrr t0, mstatus
  li t1, (3UL << 38)
  and t0, t0, t1
  bne t0, s4, fail
  li s9, 0
  csrw mepc, s10
  mret

m_from_u_hu:
  bltz a0, fail
  li t0, (3 << 11)
  csrs mstatus, t0
  la t0, after_u_hu
  csrw mepc, t0
  mret

m_from_hs:
  li t0, 100
  bne a7, t0, fail
  li t0, (3 << 11)
  csrs mstatus, t0
  la t0, m_stage6
  csrw mepc, t0
  mret

fail:
  /* Temporarily clear MPRV so finisher MMIO uses raw physical address */
  li t0, (1 << 17)
  csrc mstatus, t0
  li t0, RAPTOR_FINISHER_BASE
  slli t1, s11, 16
  li t2, 0x3333
  or t1, t1, t2
  sw t1, 0(t0)
2:
  j 2b

.section .bss
.balign 16384
g_root:
  .zero 16384
.balign 65536
g_napot_pool:
  .zero 65536
.balign 4096
g_l1:
  .zero 4096
g_l0:
  .zero 4096
g_high_l1:
  .zero 4096
g_high_l0:
  .zero 4096
vs_root:
  .zero 4096
vs_l1:
  .zero 4096
vs_l0:
  .zero 4096
page_a:
  .zero 4096
page_b:
  .zero 4096
page_c:
  .zero 4096
exec_page:
  .zero 4096
high_gpa_page:
  .zero 4096
pbmt_page_a:
  .zero 4096
pbmt_page_b:
  .zero 4096

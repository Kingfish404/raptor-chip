`include "rapt.svh"
`include "rapt_if.svh"
`include "rapt_dpi_c.svh"
`include "rapt_soc.svh"  // RAPT_MTIME_DIV (CSR `time` paces with CLINT mtime)

module rapt_csr #(
    parameter int XLEN = `RAPT_XLEN,
    parameter bit [7:0] R_W = 12,
    parameter bit [7:0] REG_W = 6,
    parameter bit [XLEN-1:0] RESET_VAL = 0
) (
    input clock,

    // Hart identifier injected by the cluster top. Returned verbatim by
    // CSR reads of `mhartid` (RV Priv §3.1.5). Tied to '0 today since the
    // cluster only instantiates one core; the multi-core wiring is in place.
    input [XLEN-1:0] hart_id_i,

    rou_csr_if.out   rou_csr,
    exu_csr_if.slave exu_csr,

    csr_bcast_if.out csr_bcast,

    // S-mode delegated interrupt pending signal to rou (level).
    // Asserts when (mip & mie & mideleg) has any bit set AND the interrupt is
    // globally enabled for S-mode (priv<S, or priv==S && sstatus.SIE).
    // s_int_cause carries the interrupt cause code (with MSB set), priority
    // SEI(9) > SSI(1) > STI(5) per RISC-V Priv §3.1.9.
    output logic            s_int_pending,
    output logic [XLEN-1:0] s_int_cause,

    // Interrupt controller level inputs. These drive the hardware-pending
    // bits in mip/sip; trap eligibility is still gated by mie/mstatus below.
    input timer_irq_i,
    input sw_irq_i,
    input m_ext_irq_i,
    input s_ext_irq_i,

    input reset
);
  typedef enum logic [REG_W-1:0] {
    MNONE__ = 0,
    SSTATUS,
    SIE____,
    STVEC__,

    SCOUNTE,
    MCOUNTE,

    SSCRATC,
    SEPC___,
    SCAUSE_,
    STVAL__,
    SIP____,
    STIMECMP,
    STIMECMPH,
    SATP___,

    MSTATUS,
    MISA___,
    MEDELEG,
    MIDELEG,
    MIE____,
    MTVEC__,

    MSTATUSH,
  MENVCFG,

    MSCRATCH,
    MEPC___,
    MCAUSE_,
    MTVAL__,
    MIP____,

    MCYCLE_,
    MCYCLEH,
    MINSTRET,
    MINSTRETH,
    TIME___,
    TIMEH__,

    MVENDORID,
    MARCHID,
    IMPID__,
    MHARTID
  } csr_t;

  logic [1:0] priv_mode;
  logic [XLEN-1:0] csr[64];
  logic mstatus_mie;
  csr_t waddr_reg, raddr_reg;
  logic [R_W-1:0] raddr;

  // CSR `time` MUST advance in lockstep with CLINT `mtime` (RV Priv §10).
  // Both are paced by RAPT_MTIME_DIV = RAPT_CORE_CLOCK_MHZ / RAPT_MTIME_FREQ_MHZ
  // so the kernel sees the same Hz the DTS declared. Override via VFLAGS or by
  // re-defining RAPT_MTIME_FREQ_MHZ in rapt_soc.svh.
  localparam int RAPTTimeDIV  = `RAPT_MTIME_DIV;
  localparam int RAPTTimeDIVW = (RAPTTimeDIV <= 1) ? 1 : $clog2(RAPTTimeDIV);
  logic [RAPTTimeDIVW-1:0] time_div_cnt;
  logic                    time_tick;
  logic [63:0]             time64;
  logic [63:0]             stimecmp;
  logic                    sstc_en;
  logic                    stime_irq;
  assign time_tick = (RAPTTimeDIV <= 1)
                   ? 1'b1
                   : (time_div_cnt == RAPTTimeDIVW'(RAPTTimeDIV - 1));

  generate
    if (XLEN == 64) begin : gen_time64_rv64
      assign time64 = csr[TIME___][63:0];
    end else begin : gen_time64_rv32
      assign time64 = {csr[TIMEH__][31:0], csr[TIME___][31:0]};
    end
  endgenerate

`ifdef RAPT_RV64
  assign sstc_en = csr[MENVCFG][`RAPT_CSR_MENVCFG_STCE];
`else
  assign sstc_en = 1'b0;
`endif
  assign stime_irq = sstc_en && (time64 >= stimecmp);

  // PMP state: 8 active entries (pmpcfg0/pmpcfg1; pmpcfg2/3 hardwired 0).
  // Reserved bits [6:5] of each cfg byte are WARL-zero (mask 8'h9F).
  // pmpaddr is stored in its raw CSR form (byte_addr >> 2).
  logic [7:0]      pmpcfg_r [`RAPT_PMP_NUM];
  logic [XLEN-1:0] pmpaddr_r[`RAPT_PMP_NUM];

  // PMP shadow registers (precomputed every clock from pmpcfg_r/pmpaddr_r).
  // Allows the combinational rapt_pmp module to skip the per-entry NAPOT
  // decode (XOR + AND), TOR neighbour fetch, and bit-slice extraction.
  // 1-cycle latency vs raw CSR — the pipeline already flushes on PMP CSR
  // writes (via fence/csrrw side-effects), so by the time the next L/S
  // executes the shadow has caught up.
  logic [XLEN-1:0]          pmp_napot_mask_r[`RAPT_PMP_NUM];
  logic [XLEN-1:0]          pmp_napot_base_r[`RAPT_PMP_NUM];
  logic [XLEN-1:0]          pmp_tor_lo_r    [`RAPT_PMP_NUM];
  logic [XLEN-1:0]          pmp_tor_hi_r    [`RAPT_PMP_NUM];
  logic [`RAPT_PMP_NUM-1:0] pmp_cfg_r_r;
  logic [`RAPT_PMP_NUM-1:0] pmp_cfg_w_r;
  logic [`RAPT_PMP_NUM-1:0] pmp_cfg_x_r;
  logic [`RAPT_PMP_NUM-1:0] pmp_cfg_l_r;
  logic [`RAPT_PMP_NUM-1:0] pmp_mode_off_r;
  logic [`RAPT_PMP_NUM-1:0] pmp_mode_tor_r;
  logic [`RAPT_PMP_NUM-1:0] pmp_mode_na4_r;
  logic [`RAPT_PMP_NUM-1:0] pmp_mode_napot_r;

  // trap handle
  logic [XLEN-1:0] cause_idx;
  logic smode_medeleg;
  logic smode_mideleg;
  logic smode_handle;

  // mip read-back: CLINT and PLIC levels are reflected as hardware-pending
  // bits. SSIP/STIP/SEIP remain software-writable in csr[MIP____]; SEIP is
  // ORed with the PLIC S-context line so M-mode can still inject S external
  // interrupts if needed.
  logic [XLEN-1:0] mip_eff;

  assign raddr = exu_csr.raddr;
  always_comb begin
    case (rou_csr.csr_addr)
      `RAPT_CSR_SSTATUS:   waddr_reg = SSTATUS;
      `RAPT_CSR_SIE____:   waddr_reg = SIE____;
      `RAPT_CSR_STVEC__:   waddr_reg = STVEC__;
      `RAPT_CSR_SCOUNTE:   waddr_reg = SCOUNTE;
      `RAPT_CSR_SSCRATC:   waddr_reg = SSCRATC;
      `RAPT_CSR_SEPC___:   waddr_reg = SEPC___;
      `RAPT_CSR_SCAUSE_:   waddr_reg = SCAUSE_;
      `RAPT_CSR_STVAL__:   waddr_reg = STVAL__;
      `RAPT_CSR_SIP____:   waddr_reg = SIP____;
      `RAPT_CSR_STIMECMP:  waddr_reg = STIMECMP;
      `RAPT_CSR_STIMECMPH: waddr_reg = STIMECMPH;
      `RAPT_CSR_SATP___:   waddr_reg = SATP___;
      `RAPT_CSR_MSTATUS:   waddr_reg = MSTATUS;
      `RAPT_CSR_MEDELEG:   waddr_reg = MEDELEG;
      `RAPT_CSR_MIDELEG:   waddr_reg = MIDELEG;
      `RAPT_CSR_MIE____:   waddr_reg = MIE____;
      `RAPT_CSR_MTVEC__:   waddr_reg = MTVEC__;
      `RAPT_CSR_MCOUNTE:   waddr_reg = MCOUNTE;
      `RAPT_CSR_MENVCFG:   waddr_reg = MENVCFG;
      `RAPT_CSR_MSTATUSH:  waddr_reg = MSTATUSH;
      `RAPT_CSR_MSCRATCH:  waddr_reg = MSCRATCH;
      `RAPT_CSR_MEPC___:   waddr_reg = MEPC___;
      `RAPT_CSR_MCAUSE_:   waddr_reg = MCAUSE_;
      `RAPT_CSR_MTVAL__:   waddr_reg = MTVAL__;
      `RAPT_CSR_MIP____:   waddr_reg = MIP____;
      `RAPT_CSR_MINSTRET:  waddr_reg = MINSTRET;
      `RAPT_CSR_MINSTRETH: waddr_reg = MINSTRETH;
      default:             waddr_reg = MNONE__;
    endcase
  end
  always_comb begin
    case (raddr)
      `RAPT_CSR_SSTATUS:   raddr_reg = SSTATUS;
      `RAPT_CSR_SIE____:   raddr_reg = SIE____;
      `RAPT_CSR_STVEC__:   raddr_reg = STVEC__;
      `RAPT_CSR_SCOUNTE:   raddr_reg = SCOUNTE;
      `RAPT_CSR_SSCRATC:   raddr_reg = SSCRATC;
      `RAPT_CSR_SEPC___:   raddr_reg = SEPC___;
      `RAPT_CSR_SCAUSE_:   raddr_reg = SCAUSE_;
      `RAPT_CSR_STVAL__:   raddr_reg = STVAL__;
      `RAPT_CSR_SIP____:   raddr_reg = SIP____;
      `RAPT_CSR_STIMECMP:  raddr_reg = STIMECMP;
      `RAPT_CSR_STIMECMPH: raddr_reg = STIMECMPH;
      `RAPT_CSR_SATP___:   raddr_reg = SATP___;
      `RAPT_CSR_MSTATUS:   raddr_reg = MSTATUS;
      `RAPT_CSR_MISA___:   raddr_reg = MISA___;
      `RAPT_CSR_MEDELEG:   raddr_reg = MEDELEG;
      `RAPT_CSR_MIDELEG:   raddr_reg = MIDELEG;
      `RAPT_CSR_MIE____:   raddr_reg = MIE____;
      `RAPT_CSR_MCOUNTE:   raddr_reg = MCOUNTE;
      `RAPT_CSR_MENVCFG:   raddr_reg = MENVCFG;
      `RAPT_CSR_MTVEC__:   raddr_reg = MTVEC__;
      `RAPT_CSR_MSTATUSH:  raddr_reg = MSTATUSH;
      `RAPT_CSR_MSCRATCH:  raddr_reg = MSCRATCH;
      `RAPT_CSR_MEPC___:   raddr_reg = MEPC___;
      `RAPT_CSR_MCAUSE_:   raddr_reg = MCAUSE_;
      `RAPT_CSR_MTVAL__:   raddr_reg = MTVAL__;
      `RAPT_CSR_MIP____:   raddr_reg = MIP____;
      `RAPT_CSR_MCYCLE_:   raddr_reg = MCYCLE_;
      `RAPT_CSR_MCYCLEH:   raddr_reg = MCYCLEH;
      `RAPT_CSR_CYCLE__:   raddr_reg = MCYCLE_;
      `RAPT_CSR_CYCLEH_:   raddr_reg = MCYCLEH;
      `RAPT_CSR_TIME___:   raddr_reg = TIME___;
      `RAPT_CSR_TIMEH__:   raddr_reg = TIMEH__;
      `RAPT_CSR_MINSTRET:  raddr_reg = MINSTRET;
      `RAPT_CSR_MINSTRETH: raddr_reg = MINSTRETH;
      `RAPT_CSR_INSTRET_:  raddr_reg = MINSTRET;
      `RAPT_CSR_INSTRETH:  raddr_reg = MINSTRETH;
      `RAPT_CSR_MVENDORID: raddr_reg = MVENDORID;
      `RAPT_CSR_MARCHID__: raddr_reg = MARCHID;
      `RAPT_CSR_IMPID____: raddr_reg = IMPID__;
      `RAPT_CSR_MHARTID__: raddr_reg = MHARTID;
      default:             raddr_reg = MNONE__;
    endcase
  end

  always_comb begin
    case (raddr_reg)
      SSTATUS:   exu_csr.rdata = csr[SSTATUS];
      SIE____:   exu_csr.rdata = csr[MIE____] & `RAPT_CSR_SIE_RMASK;
      STVEC__:   exu_csr.rdata = csr[STVEC__];
      SCOUNTE:   exu_csr.rdata = csr[SCOUNTE];
      MCOUNTE:   exu_csr.rdata = csr[MCOUNTE];
      SSCRATC:   exu_csr.rdata = csr[SSCRATC];
      SEPC___:   exu_csr.rdata = csr[SEPC___];
      SCAUSE_:   exu_csr.rdata = csr[SCAUSE_];
      STVAL__:   exu_csr.rdata = csr[STVAL__];
      SIP____:   exu_csr.rdata = mip_eff & `RAPT_CSR_SIP_RMASK;
      STIMECMP:  exu_csr.rdata = XLEN'(stimecmp[XLEN-1:0]);
      STIMECMPH: exu_csr.rdata = (XLEN == 32) ? XLEN'(stimecmp[63:32]) : '0;
      SATP___:   exu_csr.rdata = csr[SATP___];
      MSTATUS:   exu_csr.rdata = csr[MSTATUS];
      MISA___:   exu_csr.rdata = `RAPT_MISA;
      MEDELEG:   exu_csr.rdata = csr[MEDELEG];
      MIDELEG:   exu_csr.rdata = csr[MIDELEG];
      MIE____:   exu_csr.rdata = csr[MIE____];
      MTVEC__:   exu_csr.rdata = csr[MTVEC__];
      MENVCFG:   exu_csr.rdata = csr[MENVCFG];
      MSTATUSH:  exu_csr.rdata = csr[MSTATUSH];
      MSCRATCH:  exu_csr.rdata = csr[MSCRATCH];
      MEPC___:   exu_csr.rdata = csr[MEPC___];
      MCAUSE_:   exu_csr.rdata = csr[MCAUSE_];
      MTVAL__:   exu_csr.rdata = csr[MTVAL__];
      MIP____:   exu_csr.rdata = mip_eff;
      MCYCLE_:   exu_csr.rdata = csr[MCYCLE_];
      MCYCLEH:   exu_csr.rdata = csr[MCYCLEH];
      TIME___:   exu_csr.rdata = csr[TIME___];
      TIMEH__:   exu_csr.rdata = csr[TIMEH__];
      MINSTRET:  exu_csr.rdata = csr[MINSTRET];
      MINSTRETH: exu_csr.rdata = csr[MINSTRETH];
      MVENDORID: exu_csr.rdata = '0;
      MARCHID:   exu_csr.rdata = 'd50;
      IMPID__:   exu_csr.rdata = '0;
      MHARTID:   exu_csr.rdata = hart_id_i;
      default: begin
        // PMP CSR reads: pmpcfg0..3 each packs four cfg bytes;
        // pmpaddr0..15 from register file.
        if (raddr == `RAPT_CSR_PMPCFG0)
          exu_csr.rdata = {pmpcfg_r[3], pmpcfg_r[2], pmpcfg_r[1], pmpcfg_r[0]};
        else if (raddr == `RAPT_CSR_PMPCFG1)
          exu_csr.rdata = {pmpcfg_r[7], pmpcfg_r[6], pmpcfg_r[5], pmpcfg_r[4]};
        else if (raddr == `RAPT_CSR_PMPCFG2)
          exu_csr.rdata = {pmpcfg_r[11], pmpcfg_r[10], pmpcfg_r[9], pmpcfg_r[8]};
        else if (raddr == `RAPT_CSR_PMPCFG3)
          exu_csr.rdata = {pmpcfg_r[15], pmpcfg_r[14], pmpcfg_r[13], pmpcfg_r[12]};
        else if (raddr >= `RAPT_CSR_PMPADDR0
              && raddr <= `RAPT_CSR_PMPADDR15)
          exu_csr.rdata = pmpaddr_r[raddr[3:0]];
        else
          exu_csr.rdata = '0;
      end
    endcase
  end

  assign exu_csr.mepc = csr[MEPC___];
  assign exu_csr.sepc = csr[SEPC___];
  assign exu_csr.mtvec = csr[MTVEC__];

  assign mstatus_mie = csr[MSTATUS][`RAPT_CSR_MSTATUS_MIE_];

  assign cause_idx = 'b1 << (rou_csr.cause & 'h1f);
  // medeleg only applies to synchronous exceptions (cause MSB=0); mideleg only
  // to asynchronous interrupts (cause MSB=1). Without the MSB guard the same
  // low-5-bit index is shared between exception and interrupt cause spaces,
  // which would mis-delegate e.g. M-timer interrupt (cause=0x8000_0007) to
  // S-mode whenever medeleg[7] (store/AMO access fault) was set.
  assign smode_medeleg = !rou_csr.cause[XLEN-1] && |(csr[MEDELEG] & cause_idx);
  assign smode_mideleg = rou_csr.cause[XLEN-1] && |(csr[MIDELEG] & cause_idx);
  assign smode_handle = (
    (priv_mode == `RAPT_PRIV_S || priv_mode == `RAPT_PRIV_U)
    && (smode_medeleg || smode_mideleg)
  );

  // ecall/ebreak delegation: check medeleg for the specific cause
  // ecall causes: U=8, S=9, M=11; ebreak cause: 3
  logic [XLEN-1:0] ecall_cause_idx;
  logic ecall_deleg, ebreak_deleg;
  assign ecall_cause_idx = (priv_mode == `RAPT_PRIV_U) ? (XLEN'(1) << 8) :
                           (priv_mode == `RAPT_PRIV_S) ? (XLEN'(1) << 9) : '0;
  assign ecall_deleg = (priv_mode != `RAPT_PRIV_M) && |(csr[MEDELEG] & ecall_cause_idx);
  assign ebreak_deleg = (priv_mode != `RAPT_PRIV_M) && csr[MEDELEG][3];

  assign csr_bcast.priv = priv_mode;
  assign csr_bcast.satp_ppn = csr[SATP___][`RAPT_CSR_SATP_PPN_W-1:0];
  assign csr_bcast.satp_asid = csr[SATP___][`RAPT_CSR_SATP_ASID_LSB +: 9];
  assign csr_bcast.immu_en = (
      (csr[SATP___][`RAPT_CSR_SATP_MODE_] == 0)
      ? 'b0
      : (priv_mode == `RAPT_PRIV_M)
        ? 'b0
        : 'b1
  );
  // Data MMU: on for S/U modes; and on for M-mode when MPRV=1 AND MPP!=M
  // (MPRV with MPP=M does not enable translation per spec §3.1.6.3).
  assign csr_bcast.dmmu_en = (
      (csr[SATP___][`RAPT_CSR_SATP_MODE_] == 0)
      ? 'b0
      : (priv_mode == `RAPT_PRIV_M)
          ? (csr[MSTATUS][`RAPT_CSR_MSTATUS_MPRV]
             && (csr[MSTATUS][`RAPT_CSR_MSTATUS_MPP_] != `RAPT_PRIV_M))
          : 'b1
  );
  assign csr_bcast.mtvec = csr[MTVEC__];
  // Trap target PC:
  //   - Exceptions (cause[MSB]=0) always go to BASE (MODE ignored).
  //   - Interrupts in Vectored mode (MODE=01) go to BASE + 4*cause[30:0].
  //   - Reserved MODE values coerced to Direct by the tvec write mask.
  // BASE is tvec with [1:0] stripped (4-byte aligned).
  logic [XLEN-1:0] mtvec_base, stvec_base;
  logic [1:0]      mtvec_mode, stvec_mode;
  logic [XLEN-1:0] vec_offset;
  logic            is_interrupt;
  logic            use_smode_tvec;
  assign mtvec_base     = {csr[MTVEC__][XLEN-1:2], 2'b00};
  assign stvec_base     = {csr[STVEC__][XLEN-1:2], 2'b00};
  assign mtvec_mode     = csr[MTVEC__][1:0];
  assign stvec_mode     = csr[STVEC__][1:0];
  assign is_interrupt   = rou_csr.cause[XLEN-1];
  assign vec_offset     = {rou_csr.cause[XLEN-3:0], 2'b00};
  assign use_smode_tvec = smode_handle
    || (rou_csr.ecall && ecall_deleg)
    || (rou_csr.ebreak && ebreak_deleg);
  assign csr_bcast.tvec = use_smode_tvec
    ? (is_interrupt && (stvec_mode == `RAPT_TVEC_MODE_VECTORED)
        ? (stvec_base + vec_offset) : stvec_base)
    : (is_interrupt && (mtvec_mode == `RAPT_TVEC_MODE_VECTORED)
        ? (mtvec_base + vec_offset) : mtvec_base);

  // Interrupt eligibility (RISC-V priv spec 1.12 §3.1.9):
  //   An M-mode interrupt i is taken iff mip[i] && mie[i] && !mideleg[i]
  //   AND (priv < M) OR (priv == M && mstatus.MIE).
  //   M-timer/M-sw are NOT delegatable (WARL 0 in mideleg), so the
  //   source-level is always M.
  // CLINT drives only MTIP/MSIP (no S-timer source); we gate them here.
  logic m_int_mask;
  assign m_int_mask = (priv_mode != `RAPT_PRIV_M)
                   || (priv_mode == `RAPT_PRIV_M
                       && csr[MSTATUS][`RAPT_CSR_MSTATUS_MIE_]);
  assign csr_bcast.timer_int_en = m_int_mask && csr[MIE____][`RAPT_CSR_MIE_MTIE];
  assign csr_bcast.sw_int_en    = m_int_mask && csr[MIE____][`RAPT_CSR_MIE_MSIE];
  assign csr_bcast.ext_int_en   = m_int_mask && csr[MIE____][`RAPT_CSR_MIE_MEIE];

  assign mip_eff = (csr[MIP____]
                    & ~((XLEN'(1) << `RAPT_CSR_MIE_MSIE)
                      | (XLEN'(1) << `RAPT_CSR_MIE_MTIE)
                      | (XLEN'(1) << `RAPT_CSR_MIE_MEIE)))
                 | ({{(XLEN-1){1'b0}}, sw_irq_i} << `RAPT_CSR_MIE_MSIE)
                 | ({{(XLEN-1){1'b0}}, timer_irq_i} << `RAPT_CSR_MIE_MTIE)
                 | ({{(XLEN-1){1'b0}}, stime_irq} << `RAPT_CSR_MIE_STIE)
                 | ({{(XLEN-1){1'b0}}, m_ext_irq_i} << `RAPT_CSR_MIE_MEIE)
                 | ({{(XLEN-1){1'b0}}, s_ext_irq_i} << `RAPT_CSR_MIE_SEIE);

  // ----- S-mode delegated interrupt evaluation (Priv §3.1.9) --------------
  // An S-mode interrupt i fires iff: mip[i] && mie[i] && mideleg[i] && enable,
  // where enable = (priv<S) || (priv==S && sstatus.SIE).
  // M-mode is never preempted by S-mode (handled by mask: priv==M -> disabled).
  // Note: with sstc absent, OpenSBI manually sets mip.STIP from M-mode to
  // signal pending S-timer. mip is software-writable here (full-width else
  // branch in the always_ff), so OpenSBI's csrs/csrc on mip.STIP/SSIP work.
  logic            s_int_global_en;
  logic [XLEN-1:0] s_int_active;
  assign s_int_global_en = (priv_mode == `RAPT_PRIV_U)
      || ((priv_mode == `RAPT_PRIV_S) && csr[MSTATUS][`RAPT_CSR_MSTATUS_SIE_]);
  assign s_int_active = mip_eff & csr[MIE____] & csr[MIDELEG]
                      & {XLEN{s_int_global_en}};
  assign s_int_pending = |s_int_active;
  // Priority SEI > SSI > STI (matches Priv §3.1.9 order for S-level sources).
  assign s_int_cause   = (XLEN'(1) << (XLEN-1)) | (
      s_int_active[9] ? XLEN'(9)
    : s_int_active[1] ? XLEN'(1)
    :                   XLEN'(5)
  );

  // MPRV / MPP broadcast (consumed by L1D effective-privilege logic)
  assign csr_bcast.mprv = csr[MSTATUS][`RAPT_CSR_MSTATUS_MPRV];
  assign csr_bcast.mpp  = csr[MSTATUS][`RAPT_CSR_MSTATUS_MPP_];

  // mstatus privileged guard bits for illegal-inst checks.
  assign csr_bcast.tsr        = csr[MSTATUS][`RAPT_CSR_MSTATUS_TSR_];
  assign csr_bcast.tvm        = csr[MSTATUS][`RAPT_CSR_MSTATUS_TVM_];
  assign csr_bcast.tw         = csr[MSTATUS][`RAPT_CSR_MSTATUS_TW__];
  assign csr_bcast.mcounteren = csr[MCOUNTE][2:0];
  assign csr_bcast.scounteren = csr[SCOUNTE][2:0];
  assign csr_bcast.sum        = csr[MSTATUS][`RAPT_CSR_MSTATUS_SUM_];
  assign csr_bcast.mxr        = csr[MSTATUS][`RAPT_CSR_MSTATUS_MXR_];
  assign csr_bcast.sbe        = csr[MSTATUSH][`RAPT_CSR_MSTATUSH_SBE];

  // PMP broadcast
  always_comb begin
    for (int gi = 0; gi < `RAPT_PMP_NUM; gi++) begin
      csr_bcast.pmpcfg[gi]  = pmpcfg_r[gi];
      csr_bcast.pmpaddr[gi] = pmpaddr_r[gi];
      csr_bcast.pmp_napot_mask[gi] = pmp_napot_mask_r[gi];
      csr_bcast.pmp_napot_base[gi] = pmp_napot_base_r[gi];
      csr_bcast.pmp_tor_lo[gi]     = pmp_tor_lo_r[gi];
      csr_bcast.pmp_tor_hi[gi]     = pmp_tor_hi_r[gi];
    end
    csr_bcast.pmp_cfg_r      = pmp_cfg_r_r;
    csr_bcast.pmp_cfg_w      = pmp_cfg_w_r;
    csr_bcast.pmp_cfg_x      = pmp_cfg_x_r;
    csr_bcast.pmp_cfg_l      = pmp_cfg_l_r;
    csr_bcast.pmp_mode_off   = pmp_mode_off_r;
    csr_bcast.pmp_mode_tor   = pmp_mode_tor_r;
    csr_bcast.pmp_mode_na4   = pmp_mode_na4_r;
    csr_bcast.pmp_mode_napot = pmp_mode_napot_r;
  end

  // PMP shadow registers — derived from pmpcfg_r/pmpaddr_r every clock.
  // Updates 1 cycle after the underlying CSR write, which is invisible to
  // software because the PMP CSR write itself triggers a pipeline flush
  // and any subsequent load/store is at least 2 cycles downstream.
  always_ff @(posedge clock) begin
    if (reset) begin
      for (int i = 0; i < `RAPT_PMP_NUM; i++) begin
        pmp_napot_mask_r[i] <= '0;
        pmp_napot_base_r[i] <= '0;
        pmp_tor_lo_r[i]     <= '0;
        pmp_tor_hi_r[i]     <= '0;
      end
      pmp_cfg_r_r      <= '0;
      pmp_cfg_w_r      <= '0;
      pmp_cfg_x_r      <= '0;
      pmp_cfg_l_r      <= '0;
      pmp_mode_off_r   <= '1;  // OFF by default
      pmp_mode_tor_r   <= '0;
      pmp_mode_na4_r   <= '0;
      pmp_mode_napot_r <= '0;
    end else begin
      for (int i = 0; i < `RAPT_PMP_NUM; i++) begin
        // NAPOT closed-form: mask = pmpaddr ^ (pmpaddr + 1), base = pmpaddr & ~mask.
        // Computed on the fast pmpaddr_r -> FF path, kept off the LSU/L1D critical path.
        pmp_napot_mask_r[i] <= pmpaddr_r[i] ^ (pmpaddr_r[i] + {{(XLEN-1){1'b0}}, 1'b1});
        pmp_napot_base_r[i] <= pmpaddr_r[i]
          & ~(pmpaddr_r[i]
          ^ (pmpaddr_r[i] + {{(XLEN-1){1'b0}}, 1'b1}));
        pmp_tor_lo_r[i]     <= (i == 0) ? '0 : pmpaddr_r[i-1];
        pmp_tor_hi_r[i]     <= pmpaddr_r[i];
        pmp_cfg_r_r[i]      <= pmpcfg_r[i][`RAPT_PMPCFG_R_];
        pmp_cfg_w_r[i]      <= pmpcfg_r[i][`RAPT_PMPCFG_W_];
        pmp_cfg_x_r[i]      <= pmpcfg_r[i][`RAPT_PMPCFG_X_];
        pmp_cfg_l_r[i]      <= pmpcfg_r[i][`RAPT_PMPCFG_L_];
        pmp_mode_off_r[i]   <= (pmpcfg_r[i][`RAPT_PMPCFG_A_] == `RAPT_PMP_A_OFF);
        pmp_mode_tor_r[i]   <= (pmpcfg_r[i][`RAPT_PMPCFG_A_] == `RAPT_PMP_A_TOR);
        pmp_mode_na4_r[i]   <= (pmpcfg_r[i][`RAPT_PMPCFG_A_] == `RAPT_PMP_A_NA4);
        pmp_mode_napot_r[i] <= (pmpcfg_r[i][`RAPT_PMPCFG_A_] == `RAPT_PMP_A_NAPOT);
      end
    end
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      priv_mode <= `RAPT_PRIV_M;
      csr[MCAUSE_] <= RESET_VAL;
      csr[MEPC___] <= RESET_VAL;
      csr[MTVEC__] <= RESET_VAL;
      csr[MSTATUS] <= RESET_VAL;
      csr[MCYCLE_] <= RESET_VAL;
      csr[MCYCLEH] <= RESET_VAL;
      csr[TIME___] <= RESET_VAL;
      csr[TIMEH__] <= RESET_VAL;
      csr[MINSTRET] <= RESET_VAL;
      csr[MINSTRETH] <= RESET_VAL;
      csr[MSTATUSH] <= '0;
      csr[MENVCFG] <= '0;
      csr[MCOUNTE] <= '0;
      csr[SCOUNTE] <= '0;
      csr[MIDELEG] <= '0;
      stimecmp <= 64'hFFFF_FFFF_FFFF_FFFF;
      for (int i = 0; i < `RAPT_PMP_NUM; i++) begin
        pmpcfg_r[i]  <= '0;
        pmpaddr_r[i] <= '0;
      end
      time_div_cnt <= '0;
    end else begin
      if (time_tick) begin
        csr[TIME___] <= csr[TIME___] + 1;
        if (csr[TIME___] == ~'h0) begin
          csr[TIMEH__] <= csr[TIMEH__] + 1;
        end
        time_div_cnt <= '0;
      end else begin
        time_div_cnt <= time_div_cnt + RAPTTimeDIVW'(1);
      end
      csr[MCYCLE_] <= csr[MCYCLE_] + 1;
      if (csr[MCYCLE_] == ~'h0) begin
        csr[MCYCLEH] <= csr[MCYCLEH] + 1;
      end
      csr[MINSTRET] <= csr[MINSTRET] + XLEN'(rou_csr.retire_a) + XLEN'(rou_csr.retire_b);
      if (csr[MINSTRET] + XLEN'(rou_csr.retire_a) + XLEN'(rou_csr.retire_b) < csr[MINSTRET]) begin
        csr[MINSTRETH] <= csr[MINSTRETH] + 1;
      end
      if (rou_csr.valid) begin
        if (rou_csr.csr_wen) begin
          if (rou_csr.csr_addr == `RAPT_CSR_PMPCFG0) begin
            // pmpcfg0 packs entries 0..3 (byte i => entry i).
            // L-bit locked cfgs ignore further writes (until reset).
            // Reserved bits [6:5] are WARL-zero (mask 8'h9F).
            for (int pi = 0; pi < 4; pi++) begin
              if (!pmpcfg_r[pi][`RAPT_PMPCFG_L_]) begin
                pmpcfg_r[pi] <= rou_csr.csr_wdata[pi*8 +: 8] & 8'h9F;
              end
            end
          end else if (rou_csr.csr_addr == `RAPT_CSR_PMPCFG1) begin
            for (int pi = 0; pi < 4; pi++) begin
              if (!pmpcfg_r[pi + 4][`RAPT_PMPCFG_L_]) begin
                pmpcfg_r[pi + 4] <= rou_csr.csr_wdata[pi*8 +: 8] & 8'h9F;
              end
            end
          end else if (rou_csr.csr_addr == `RAPT_CSR_PMPCFG2) begin
            for (int pi = 0; pi < 4; pi++) begin
              if (!pmpcfg_r[pi + 8][`RAPT_PMPCFG_L_]) begin
                pmpcfg_r[pi + 8] <= rou_csr.csr_wdata[pi*8 +: 8] & 8'h9F;
              end
            end
          end else if (rou_csr.csr_addr == `RAPT_CSR_PMPCFG3) begin
            for (int pi = 0; pi < 4; pi++) begin
              if (!pmpcfg_r[pi + 12][`RAPT_PMPCFG_L_]) begin
                pmpcfg_r[pi + 12] <= rou_csr.csr_wdata[pi*8 +: 8] & 8'h9F;
              end
            end
          end else if (rou_csr.csr_addr >= `RAPT_CSR_PMPADDR0
                    && rou_csr.csr_addr <= `RAPT_CSR_PMPADDR15) begin
            // pmpaddr[i] writable unless entry i is locked OR the next entry
            // is locked AND its A-mode is TOR (entry i then forms TOR's lower bound).
            automatic logic [3:0] pidx = rou_csr.csr_addr[3:0];
            automatic logic self_locked = pmpcfg_r[pidx][`RAPT_PMPCFG_L_];
            automatic logic tor_locked  = (pidx < 4'(`RAPT_PMP_NUM - 1))
                ? (pmpcfg_r[pidx + 4'd1][`RAPT_PMPCFG_L_]
                   && (pmpcfg_r[pidx + 4'd1][`RAPT_PMPCFG_A_] == `RAPT_PMP_A_TOR))
                : 1'b0;
            if (!self_locked && !tor_locked) begin
              pmpaddr_r[pidx] <= rou_csr.csr_wdata;
            end
          end else if (waddr_reg == MEDELEG) begin
            csr[waddr_reg] <= (rou_csr.csr_wdata & `RAPT_CSR_MEDELEG_WMASK);
          end else if (waddr_reg == MIDELEG) begin
            // Only SSI(1)/STI(5)/SEI(9) are delegatable.
            csr[waddr_reg] <= (rou_csr.csr_wdata & `RAPT_CSR_MIDELEG_WMASK);
          end else if (waddr_reg == MCOUNTE || waddr_reg == SCOUNTE) begin
            // Only CY/TM/IR (bits [2:0]) modeled; HPM bits WARL-zero.
            csr[waddr_reg] <= (rou_csr.csr_wdata & `RAPT_CSR_COUNTEREN_WMASK);
          end else if (waddr_reg == MENVCFG) begin
            csr[MENVCFG] <= (rou_csr.csr_wdata & `RAPT_CSR_MENVCFG_WMASK);
          end else if (waddr_reg == STIMECMP) begin
            if (XLEN == 64) begin
              stimecmp <= 64'(rou_csr.csr_wdata);
            end else begin
              stimecmp[31:0] <= rou_csr.csr_wdata[31:0];
            end
          end else if (waddr_reg == STIMECMPH) begin
            if (XLEN == 32) begin
              stimecmp[63:32] <= rou_csr.csr_wdata[31:0];
            end
          end else if (waddr_reg == MSTATUSH) begin
            // SBE/MBE are WARL-zero (little-endian only).
            csr[MSTATUSH] <= '0;
          end else if (waddr_reg == MSTATUS) begin
            // Write mask: exclude SD(31, read-only) and VS(10:9, hardwired 0 — no V ext)
            // SD recomputed from FS dirty (14:13==2'b11) or XS dirty (16:15==2'b11)
            csr[MSTATUS] <= (rou_csr.csr_wdata & `RAPT_CSR_MSTATUS_WMASK)
                          | ((rou_csr.csr_wdata[14:13] == 2'b11
                            || rou_csr.csr_wdata[16:15] == 2'b11) ? `RAPT_CSR_MSTATUS_SD : 32'h0);
            csr[SSTATUS] <= (rou_csr.csr_wdata & `RAPT_CSR_SSTATUS_WMASK)
                          | ((rou_csr.csr_wdata[14:13] == 2'b11
                            || rou_csr.csr_wdata[16:15] == 2'b11) ? `RAPT_CSR_MSTATUS_SD : 32'h0);
          end else if (waddr_reg == SSTATUS) begin
            // sstatus-writable fields: SIE(1) SPIE(5) UBE(6) SPP(8) FS(14:13) XS(16:15) SUM(18) MXR(19)
            csr[SSTATUS] <= (rou_csr.csr_wdata & `RAPT_CSR_SSTATUS_WMASK)
                          | ((rou_csr.csr_wdata[14:13] == 2'b11
                            || rou_csr.csr_wdata[16:15] == 2'b11) ? `RAPT_CSR_MSTATUS_SD : 32'h0);
            csr[MSTATUS] <= (csr[MSTATUS] & ~`RAPT_CSR_SSTATUS_CMASK)
                          | (rou_csr.csr_wdata & `RAPT_CSR_SSTATUS_WMASK)
                          | ((rou_csr.csr_wdata[14:13] == 2'b11
                            || csr[MSTATUS][16:15] == 2'b11) ? `RAPT_CSR_MSTATUS_SD : 32'h0);
          end else if (waddr_reg == SIE____) begin
            // sie is a restricted view of mie; write only the SIE-visible bits.
            csr[MIE____] <= (csr[MIE____] & ~`RAPT_CSR_SIE_WMASK)
                          | (rou_csr.csr_wdata & `RAPT_CSR_SIE_WMASK);
          end else if (waddr_reg == SIP____) begin
            // sip is a restricted view of mip; only SSIP (bit 1) is software-writable.
            csr[MIP____] <= (csr[MIP____] & ~`RAPT_CSR_SIP_WMASK)
                          | (rou_csr.csr_wdata & `RAPT_CSR_SIP_WMASK);
          end else if (waddr_reg == MIP____) begin
            csr[MIP____] <= (csr[MIP____] & ~`RAPT_CSR_MIP_WMASK)
                          | (rou_csr.csr_wdata & `RAPT_CSR_MIP_WMASK);
          end else if (waddr_reg == MTVEC__ || waddr_reg == STVEC__) begin
            // WARL on MODE field [1:0]: only Direct(00) and Vectored(01) are
            // defined; reserved values (10/11) coerce to Direct(00).
            // BASE field [XLEN-1:2] is fully writable (must be 4-byte aligned).
            csr[waddr_reg] <= {rou_csr.csr_wdata[XLEN-1:2],
                               rou_csr.csr_wdata[1] ? 2'b00 : rou_csr.csr_wdata[1:0]};
          end else if (waddr_reg == MEPC___ || waddr_reg == SEPC___) begin
            // WARL: mepc/sepc bit [0] is always 0 per RISC-V priv spec.
            // With C-ext, bit [1] is writable (2-byte alignment). Without C,
            // hardware may also clear bit [1] but keeping it is spec-legal.
            csr[waddr_reg] <= {rou_csr.csr_wdata[XLEN-1:1], 1'b0};
          end else begin
            csr[waddr_reg] <= (rou_csr.csr_wdata);
          end
        end
        if (rou_csr.ecall) begin
          if (ecall_deleg) begin
            // Delegate to S-mode
            csr[SEPC___] <= rou_csr.pc;
            csr[SCAUSE_] <= priv_mode == `RAPT_PRIV_S ? `RAPT_CAUSE_ECALL_S : `RAPT_CAUSE_ECALL_U;
            csr[STVAL__] <= 0;
            csr[MSTATUS][`RAPT_CSR_MSTATUS_SPIE] <= csr[MSTATUS][`RAPT_CSR_MSTATUS_SIE_];
            csr[SSTATUS][`RAPT_CSR_MSTATUS_SPIE] <= csr[SSTATUS][`RAPT_CSR_MSTATUS_SIE_];
            csr[MSTATUS][`RAPT_CSR_MSTATUS_SIE_] <= 'h0;
            csr[SSTATUS][`RAPT_CSR_MSTATUS_SIE_] <= 'h0;
            csr[MSTATUS][`RAPT_CSR_MSTATUS_SPP_] <= (priv_mode == `RAPT_PRIV_S);
            csr[SSTATUS][`RAPT_CSR_MSTATUS_SPP_] <= (priv_mode == `RAPT_PRIV_S);
            priv_mode <= `RAPT_PRIV_S;
          end else begin
            // Handle in M-mode
            priv_mode <= `RAPT_PRIV_M;
            csr[MCAUSE_] <= priv_mode == `RAPT_PRIV_M
              ? `RAPT_CAUSE_ECALL_M
              : priv_mode == `RAPT_PRIV_S
                ? `RAPT_CAUSE_ECALL_S : `RAPT_CAUSE_ECALL_U;
            csr[MSTATUS][`RAPT_CSR_MSTATUS_MPP_] <= priv_mode;
            csr[MSTATUS][`RAPT_CSR_MSTATUS_MPIE] <= mstatus_mie;
            csr[MSTATUS][`RAPT_CSR_MSTATUS_MIE_] <= 1'b0;
            csr[MEPC___] <= rou_csr.pc;
            csr[MTVAL__] <= 0;
          end
        end else if (rou_csr.mret) begin
          priv_mode <= csr[MSTATUS][`RAPT_CSR_MSTATUS_MPP_];
          csr[MSTATUS] <= {
            csr[MSTATUS][XLEN-1:13],
            `RAPT_PRIV_U,
            csr[MSTATUS][10:8],
            1'b1,
            csr[MSTATUS][6:4],
            csr[MSTATUS][`RAPT_CSR_MSTATUS_MPIE],
            csr[MSTATUS][2:0]
          };
          if (csr[MSTATUS][`RAPT_CSR_MSTATUS_MPP_] != `RAPT_PRIV_M) begin
            csr[MSTATUS][`RAPT_CSR_MSTATUS_MPRV] <= 1'b0;
          end
        end else if (rou_csr.sret) begin
          priv_mode <= csr[MSTATUS][`RAPT_CSR_MSTATUS_SPP_] == 1'b1 ? `RAPT_PRIV_S : `RAPT_PRIV_U;
          csr[MSTATUS] <= {
            csr[MSTATUS][XLEN-1:9],
            1'b0,  // SPP = 0
            csr[MSTATUS][7:6],  // preserve MPIE, bit 6
            1'b1,  // SPIE = 1
            csr[MSTATUS][4:2],  // preserve MIE, bits 4,2
            csr[MSTATUS][`RAPT_CSR_MSTATUS_SPIE],  // SIE <- SPIE
            csr[MSTATUS][0]
          };
          csr[SSTATUS] <= {
            csr[SSTATUS][XLEN-1:9],
            1'b0,  // SPP = 0
            csr[SSTATUS][7:6],
            1'b1,  // SPIE = 1
            csr[SSTATUS][4:2],
            csr[SSTATUS][`RAPT_CSR_MSTATUS_SPIE],  // SIE <- SPIE
            csr[SSTATUS][0]
          };
          csr[MSTATUS][`RAPT_CSR_MSTATUS_MPRV] <= 1'b0;
        end else if (rou_csr.ebreak) begin
          if (ebreak_deleg) begin
            // Delegate to S-mode
            csr[SEPC___] <= rou_csr.pc;
            csr[SCAUSE_] <= `RAPT_CAUSE_BREAKPOINT;
            csr[STVAL__] <= rou_csr.pc;
            csr[MSTATUS][`RAPT_CSR_MSTATUS_SPIE] <= csr[MSTATUS][`RAPT_CSR_MSTATUS_SIE_];
            csr[SSTATUS][`RAPT_CSR_MSTATUS_SPIE] <= csr[SSTATUS][`RAPT_CSR_MSTATUS_SIE_];
            csr[MSTATUS][`RAPT_CSR_MSTATUS_SIE_] <= 'h0;
            csr[SSTATUS][`RAPT_CSR_MSTATUS_SIE_] <= 'h0;
            csr[MSTATUS][`RAPT_CSR_MSTATUS_SPP_] <= (priv_mode == `RAPT_PRIV_S);
            csr[SSTATUS][`RAPT_CSR_MSTATUS_SPP_] <= (priv_mode == `RAPT_PRIV_S);
            priv_mode <= `RAPT_PRIV_S;
          end else begin
            // Handle in M-mode
            priv_mode <= `RAPT_PRIV_M;
            csr[MCAUSE_] <= `RAPT_CAUSE_BREAKPOINT;
            csr[MSTATUS][`RAPT_CSR_MSTATUS_MPP_] <= priv_mode;
            csr[MSTATUS][`RAPT_CSR_MSTATUS_MPIE] <= mstatus_mie;
            csr[MSTATUS][`RAPT_CSR_MSTATUS_MIE_] <= 1'b0;
            csr[MEPC___] <= rou_csr.pc;
            csr[MTVAL__] <= rou_csr.pc;
          end
        end else if (rou_csr.trap) begin
          if (smode_handle) begin
            csr[STVAL__] <= rou_csr.tval;
            csr[SEPC___] <= rou_csr.pc;
            csr[SCAUSE_] <= rou_csr.cause;

            csr[MSTATUS][`RAPT_CSR_MSTATUS_SIE_] <= 'h0;
            csr[SSTATUS][`RAPT_CSR_MSTATUS_SIE_] <= 'h0;

            csr[MSTATUS][`RAPT_CSR_MSTATUS_SPIE] <= csr[MSTATUS][`RAPT_CSR_MSTATUS_SIE_];
            csr[SSTATUS][`RAPT_CSR_MSTATUS_SPIE] <= csr[SSTATUS][`RAPT_CSR_MSTATUS_SIE_];

            csr[MSTATUS][`RAPT_CSR_MSTATUS_SPP_] <= (priv_mode == `RAPT_PRIV_S);
            csr[SSTATUS][`RAPT_CSR_MSTATUS_SPP_] <= (priv_mode == `RAPT_PRIV_S);

            priv_mode <= `RAPT_PRIV_S;
          end else begin
            csr[MCAUSE_] <= rou_csr.cause;

            csr[MSTATUS][`RAPT_CSR_MSTATUS_MPP_] <= priv_mode;
            csr[MSTATUS][`RAPT_CSR_MSTATUS_MPIE] <= mstatus_mie;
            csr[MSTATUS][`RAPT_CSR_MSTATUS_MIE_] <= 1'b0;

            csr[MEPC___] <= rou_csr.pc;
            csr[MTVAL__] <= rou_csr.tval;
            priv_mode <= `RAPT_PRIV_M;
`ifdef RAPT_DEBUG_PMP
            $display(
              "[%0t] CSR_TRAP_M cause=%h mepc=%h mtval=%h",
              $time, rou_csr.cause, rou_csr.pc, rou_csr.tval);
`endif
          end
        end
      end

    end
  end

  // Difftest / external visibility shadow: keep csr[SIE____] and
  // csr[SIP____] in lockstep with the masked M-side storage. The sie/sip
  // CSRs are restricted views of mie/mip; software writes are redirected
  // into csr[MIE____] / csr[MIP____] above, so the SIE/SIP slots would
  // otherwise stay 0 and break difftest's pointer compare against NEMU
  // (which mirrors `CSR_SIE = MIE & SIE_RMASK` after every insn). Use a
  // dedicated combinational shadow (not csr[SIE____]/csr[SIP____] NBA)
  // so the value is current within the same eval as the MIE write.
  logic [XLEN-1:0] csr_sie_shadow /* verilator public_flat_rd */;
  logic [XLEN-1:0] csr_sip_shadow /* verilator public_flat_rd */;
  assign csr_sie_shadow = csr[MIE____] & `RAPT_CSR_SIE_RMASK;
  assign csr_sip_shadow = mip_eff      & `RAPT_CSR_SIP_RMASK;
endmodule

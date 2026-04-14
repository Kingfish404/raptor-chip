`include "ysyx.svh"
`include "ysyx_if.svh"
`include "ysyx_dpi_c.svh"

module ysyx_csr #(
    parameter bit [7:0] XLEN = `YSYX_XLEN,
    parameter bit [7:0] R_W = 12,
    parameter bit [7:0] REG_W = 6,
    parameter bit [XLEN-1:0] RESET_VAL = 0
) (
    input clock,

    rou_csr_if.out   rou_csr,
    exu_csr_if.slave exu_csr,

    csr_bcast_if.out csr_bcast,

    input reset
);
  typedef enum logic [REG_W-1:0] {
    MNONE__ = 0,
    SSTATUS,
    SIE____,
    STVEC__,

    SCOUNTE,

    SSCRATC,
    SEPC___,
    SCAUSE_,
    STVAL__,
    SIP____,
    SATP___,

    MSTATUS,
    MISA___,
    MEDELEG,
    MIDELEG,
    MIE____,
    MTVEC__,

    MSTATUSH,

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

  // trap handle
  logic [XLEN-1:0] cause_idx;
  logic smode_medeleg;
  logic smode_mideleg;
  logic smode_handle;

  assign raddr = exu_csr.raddr;
  always_comb begin
    case (rou_csr.csr_addr)
      `YSYX_CSR_SSTATUS:   waddr_reg = SSTATUS;
      `YSYX_CSR_SIE____:   waddr_reg = SIE____;
      `YSYX_CSR_STVEC__:   waddr_reg = STVEC__;
      `YSYX_CSR_SCOUNTE:   waddr_reg = SCOUNTE;
      `YSYX_CSR_SSCRATC:   waddr_reg = SSCRATC;
      `YSYX_CSR_SEPC___:   waddr_reg = SEPC___;
      `YSYX_CSR_SCAUSE_:   waddr_reg = SCAUSE_;
      `YSYX_CSR_STVAL__:   waddr_reg = STVAL__;
      `YSYX_CSR_SIP____:   waddr_reg = SIP____;
      `YSYX_CSR_SATP___:   waddr_reg = SATP___;
      `YSYX_CSR_MSTATUS:   waddr_reg = MSTATUS;
      `YSYX_CSR_MEDELEG:   waddr_reg = MEDELEG;
      `YSYX_CSR_MIDELEG:   waddr_reg = MIDELEG;
      `YSYX_CSR_MIE____:   waddr_reg = MIE____;
      `YSYX_CSR_MTVEC__:   waddr_reg = MTVEC__;
      `YSYX_CSR_MSCRATCH:  waddr_reg = MSCRATCH;
      `YSYX_CSR_MEPC___:   waddr_reg = MEPC___;
      `YSYX_CSR_MCAUSE_:   waddr_reg = MCAUSE_;
      `YSYX_CSR_MTVAL__:   waddr_reg = MTVAL__;
      `YSYX_CSR_MIP____:   waddr_reg = MIP____;
      `YSYX_CSR_MINSTRET:  waddr_reg = MINSTRET;
      `YSYX_CSR_MINSTRETH: waddr_reg = MINSTRETH;
      default:             waddr_reg = MNONE__;
    endcase
  end
  always_comb begin
    case (raddr)
      `YSYX_CSR_SSTATUS:   raddr_reg = SSTATUS;
      `YSYX_CSR_SIE____:   raddr_reg = SIE____;
      `YSYX_CSR_STVEC__:   raddr_reg = STVEC__;
      `YSYX_CSR_SCOUNTE:   raddr_reg = SCOUNTE;
      `YSYX_CSR_SSCRATC:   raddr_reg = SSCRATC;
      `YSYX_CSR_SEPC___:   raddr_reg = SEPC___;
      `YSYX_CSR_SCAUSE_:   raddr_reg = SCAUSE_;
      `YSYX_CSR_STVAL__:   raddr_reg = STVAL__;
      `YSYX_CSR_SIP____:   raddr_reg = SIP____;
      `YSYX_CSR_SATP___:   raddr_reg = SATP___;
      `YSYX_CSR_MSTATUS:   raddr_reg = MSTATUS;
      `YSYX_CSR_MISA___:   raddr_reg = MISA___;
      `YSYX_CSR_MEDELEG:   raddr_reg = MEDELEG;
      `YSYX_CSR_MIDELEG:   raddr_reg = MIDELEG;
      `YSYX_CSR_MIE____:   raddr_reg = MIE____;
      `YSYX_CSR_MTVEC__:   raddr_reg = MTVEC__;
      `YSYX_CSR_MSCRATCH:  raddr_reg = MSCRATCH;
      `YSYX_CSR_MEPC___:   raddr_reg = MEPC___;
      `YSYX_CSR_MCAUSE_:   raddr_reg = MCAUSE_;
      `YSYX_CSR_MTVAL__:   raddr_reg = MTVAL__;
      `YSYX_CSR_MIP____:   raddr_reg = MIP____;
      `YSYX_CSR_MCYCLE_:   raddr_reg = MCYCLE_;
      `YSYX_CSR_MCYCLEH:   raddr_reg = MCYCLEH;
      `YSYX_CSR_CYCLE__:   raddr_reg = MCYCLE_;
      `YSYX_CSR_CYCLEH_:   raddr_reg = MCYCLEH;
      `YSYX_CSR_TIME___:   raddr_reg = TIME___;
      `YSYX_CSR_TIMEH__:   raddr_reg = TIMEH__;
      `YSYX_CSR_MINSTRET:  raddr_reg = MINSTRET;
      `YSYX_CSR_MINSTRETH: raddr_reg = MINSTRETH;
      `YSYX_CSR_INSTRET_:  raddr_reg = MINSTRET;
      `YSYX_CSR_INSTRETH:  raddr_reg = MINSTRETH;
      `YSYX_CSR_MVENDORID: raddr_reg = MVENDORID;
      `YSYX_CSR_MARCHID__: raddr_reg = MARCHID;
      `YSYX_CSR_IMPID____: raddr_reg = IMPID__;
      `YSYX_CSR_MHARTID__: raddr_reg = MHARTID;
      default:             raddr_reg = MNONE__;
    endcase
  end

  always_comb begin
    case (raddr_reg)
      SSTATUS:   exu_csr.rdata = csr[SSTATUS];
      SIE____:   exu_csr.rdata = csr[SIE____];
      STVEC__:   exu_csr.rdata = csr[STVEC__];
      SCOUNTE:   exu_csr.rdata = csr[SCOUNTE];
      SSCRATC:   exu_csr.rdata = csr[SSCRATC];
      SEPC___:   exu_csr.rdata = csr[SEPC___];
      SCAUSE_:   exu_csr.rdata = csr[SCAUSE_];
      STVAL__:   exu_csr.rdata = csr[STVAL__];
      SIP____:   exu_csr.rdata = csr[SIP____];
      SATP___:   exu_csr.rdata = csr[SATP___];
      MSTATUS:   exu_csr.rdata = csr[MSTATUS];
      MISA___:   exu_csr.rdata = `YSYX_MISA;
      MEDELEG:   exu_csr.rdata = csr[MEDELEG];
      MIDELEG:   exu_csr.rdata = csr[MIDELEG];
      MIE____:   exu_csr.rdata = csr[MIE____];
      MTVEC__:   exu_csr.rdata = csr[MTVEC__];
      MSCRATCH:  exu_csr.rdata = csr[MSCRATCH];
      MEPC___:   exu_csr.rdata = csr[MEPC___];
      MCAUSE_:   exu_csr.rdata = csr[MCAUSE_];
      MTVAL__:   exu_csr.rdata = csr[MTVAL__];
      MIP____:   exu_csr.rdata = csr[MIP____];
      MCYCLE_:   exu_csr.rdata = csr[MCYCLE_];
      MCYCLEH:   exu_csr.rdata = csr[MCYCLEH];
      TIME___:   exu_csr.rdata = csr[TIME___];
      TIMEH__:   exu_csr.rdata = csr[TIMEH__];
      MINSTRET:  exu_csr.rdata = csr[MINSTRET];
      MINSTRETH: exu_csr.rdata = csr[MINSTRETH];
      MVENDORID: exu_csr.rdata = '0;
      MARCHID:   exu_csr.rdata = 'd50;
      IMPID__:   exu_csr.rdata = '0;
      MHARTID:   exu_csr.rdata = '0;
      default:   exu_csr.rdata = '0;
    endcase
  end

  assign exu_csr.mepc = csr[MEPC___];
  assign exu_csr.sepc = csr[SEPC___];
  assign exu_csr.mtvec = csr[MTVEC__];

  assign mstatus_mie = csr[MSTATUS][`YSYX_CSR_MSTATUS_MIE_];

  assign cause_idx = 'b1 << (rou_csr.cause & 'h1f);
  assign smode_medeleg = |(csr[MEDELEG] & cause_idx);
  assign smode_mideleg = rou_csr.cause[XLEN-1] && |(csr[MIDELEG] & cause_idx);
  assign smode_handle = (
    (priv_mode == `YSYX_PRIV_S || priv_mode == `YSYX_PRIV_U)
    && (smode_medeleg || smode_mideleg)
  );

  // ecall/ebreak delegation: check medeleg for the specific cause
  // ecall causes: U=8, S=9, M=11; ebreak cause: 3
  logic [XLEN-1:0] ecall_cause_idx;
  logic ecall_deleg, ebreak_deleg;
  assign ecall_cause_idx = (priv_mode == `YSYX_PRIV_U) ? (XLEN'(1) << 8) :
                           (priv_mode == `YSYX_PRIV_S) ? (XLEN'(1) << 9) : '0;
  assign ecall_deleg = (priv_mode != `YSYX_PRIV_M) && |(csr[MEDELEG] & ecall_cause_idx);
  assign ebreak_deleg = (priv_mode != `YSYX_PRIV_M) && csr[MEDELEG][3];

  assign csr_bcast.priv = priv_mode;
  assign csr_bcast.satp_ppn = csr[SATP___][21:0];
  assign csr_bcast.satp_asid = csr[SATP___][30:22];
  assign csr_bcast.immu_en = (
      (csr[SATP___][`YSYX_CSR_SATP_MODE_] == 0)
      ? 'b0
      : (priv_mode == `YSYX_PRIV_M)
        ? 'b0
        : 'b1
  );
  assign csr_bcast.dmmu_en = (
      (csr[SATP___][`YSYX_CSR_SATP_MODE_] == 0)
      ? 'b0
      : (priv_mode == `YSYX_PRIV_M) && (csr[MSTATUS][`YSYX_CSR_MSTATUS_MPRV] == 0)
          ? 'b0
          : 'b1
  );
  assign csr_bcast.mtvec = csr[MTVEC__];
  assign csr_bcast.tvec = (smode_handle
    || (rou_csr.ecall && ecall_deleg)
    || (rou_csr.ebreak && ebreak_deleg))
    ? csr[STVEC__] : csr[MTVEC__];

  assign csr_bcast.timer_int_en = (
      (priv_mode == `YSYX_PRIV_M)
        ? csr[MSTATUS][`YSYX_CSR_MSTATUS_MIE_] && csr[MIE____][`YSYX_CSR_MIE_MTIE]
    : (priv_mode == `YSYX_PRIV_S)
        ? csr[SSTATUS][`YSYX_CSR_MSTATUS_SIE_] && csr[MIE____][`YSYX_CSR_MIE_STIE]
    : 'b0
  );

  assign csr_bcast.sw_int_en = (
      (priv_mode == `YSYX_PRIV_M)
        ? csr[MSTATUS][`YSYX_CSR_MSTATUS_MIE_] && csr[MIE____][`YSYX_CSR_MIE_MSIE]
    : (priv_mode == `YSYX_PRIV_S)
        ? csr[SSTATUS][`YSYX_CSR_MSTATUS_SIE_] && csr[MIE____][`YSYX_CSR_MIE_SSIE]
    : 'b0
  );

  always_ff @(posedge clock) begin
    if (reset) begin
      priv_mode <= `YSYX_PRIV_M;
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
    end else begin
      csr[TIME___] <= csr[TIME___] + 1;
      if (csr[TIME___] == ~'h0) begin
        csr[TIMEH__] <= csr[TIMEH__] + 1;
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
          if (waddr_reg == MEDELEG) begin
            csr[waddr_reg] <= (rou_csr.csr_wdata & `YSYX_CSR_MEDELEG_WMASK);
          end else if (waddr_reg == MSTATUS) begin
            // Write mask: exclude SD(31, read-only) and VS(10:9, hardwired 0 — no V ext)
            // SD recomputed from FS dirty (14:13==2'b11) or XS dirty (16:15==2'b11)
            csr[MSTATUS] <= (rou_csr.csr_wdata & `YSYX_CSR_MSTATUS_WMASK)
                          | ((rou_csr.csr_wdata[14:13] == 2'b11
                            || rou_csr.csr_wdata[16:15] == 2'b11) ? `YSYX_CSR_MSTATUS_SD : 32'h0);
            csr[SSTATUS] <= (rou_csr.csr_wdata & `YSYX_CSR_SSTATUS_WMASK)
                          | ((rou_csr.csr_wdata[14:13] == 2'b11
                            || rou_csr.csr_wdata[16:15] == 2'b11) ? `YSYX_CSR_MSTATUS_SD : 32'h0);
          end else if (waddr_reg == SSTATUS) begin
            // sstatus-writable fields: SIE(1) SPIE(5) UBE(6) SPP(8) FS(14:13) XS(16:15) SUM(18) MXR(19)
            csr[SSTATUS] <= (rou_csr.csr_wdata & `YSYX_CSR_SSTATUS_WMASK)
                          | ((rou_csr.csr_wdata[14:13] == 2'b11
                            || rou_csr.csr_wdata[16:15] == 2'b11) ? `YSYX_CSR_MSTATUS_SD : 32'h0);
            csr[MSTATUS] <= (csr[MSTATUS] & ~`YSYX_CSR_SSTATUS_CMASK)
                          | (rou_csr.csr_wdata & `YSYX_CSR_SSTATUS_WMASK)
                          | ((rou_csr.csr_wdata[14:13] == 2'b11
                            || csr[MSTATUS][16:15] == 2'b11) ? `YSYX_CSR_MSTATUS_SD : 32'h0);
          end else if (waddr_reg == SIE____) begin
            csr[waddr_reg] <= (rou_csr.csr_wdata);
            csr[MIE____]   <= csr[MIE____] | (rou_csr.csr_wdata);
          end else begin
            csr[waddr_reg] <= (rou_csr.csr_wdata);
          end
        end
        if (rou_csr.ecall) begin
          if (ecall_deleg) begin
            // Delegate to S-mode
            csr[SEPC___] <= rou_csr.pc;
            csr[SCAUSE_] <= priv_mode == `YSYX_PRIV_S ? `YSYX_CAUSE_ECALL_S : `YSYX_CAUSE_ECALL_U;
            csr[STVAL__] <= 0;
            csr[MSTATUS][`YSYX_CSR_MSTATUS_SPIE] <= csr[MSTATUS][`YSYX_CSR_MSTATUS_SIE_];
            csr[SSTATUS][`YSYX_CSR_MSTATUS_SPIE] <= csr[SSTATUS][`YSYX_CSR_MSTATUS_SIE_];
            csr[MSTATUS][`YSYX_CSR_MSTATUS_SIE_] <= 'h0;
            csr[SSTATUS][`YSYX_CSR_MSTATUS_SIE_] <= 'h0;
            if (priv_mode == `YSYX_PRIV_S) begin
              csr[MSTATUS][`YSYX_CSR_MSTATUS_SPP_] <= 'h1;
              csr[SSTATUS][`YSYX_CSR_MSTATUS_SPP_] <= 'h1;
            end
            priv_mode <= `YSYX_PRIV_S;
          end else begin
            // Handle in M-mode
            priv_mode <= `YSYX_PRIV_M;
            csr[MCAUSE_] <= priv_mode == `YSYX_PRIV_M ? `YSYX_CAUSE_ECALL_M : priv_mode == `YSYX_PRIV_S ? `YSYX_CAUSE_ECALL_S : `YSYX_CAUSE_ECALL_U;
            csr[MSTATUS][`YSYX_CSR_MSTATUS_MPP_] <= priv_mode;
            csr[MSTATUS][`YSYX_CSR_MSTATUS_MPIE] <= mstatus_mie;
            csr[MSTATUS][`YSYX_CSR_MSTATUS_MIE_] <= 1'b0;
            csr[MEPC___] <= rou_csr.pc;
            csr[MTVAL__] <= 0;
          end
        end else if (rou_csr.mret) begin
          priv_mode <= csr[MSTATUS][`YSYX_CSR_MSTATUS_MPP_];
          csr[MSTATUS] <= {
            csr[MSTATUS][XLEN-1:13],
            `YSYX_PRIV_U,
            csr[MSTATUS][10:8],
            1'b1,
            csr[MSTATUS][6:4],
            csr[MSTATUS][`YSYX_CSR_MSTATUS_MPIE],
            csr[MSTATUS][2:0]
          };
        end else if (rou_csr.sret) begin
          priv_mode <= csr[MSTATUS][`YSYX_CSR_MSTATUS_SPP_] == 1'b1 ? `YSYX_PRIV_S : `YSYX_PRIV_U;
          csr[MSTATUS] <= {
            csr[MSTATUS][XLEN-1:9],
            1'b0,  // SPP = 0
            csr[MSTATUS][7:6],  // preserve MPIE, bit 6
            1'b1,  // SPIE = 1
            csr[MSTATUS][4:2],  // preserve MIE, bits 4,2
            csr[MSTATUS][`YSYX_CSR_MSTATUS_SPIE],  // SIE <- SPIE
            csr[MSTATUS][0]
          };
          csr[SSTATUS] <= {
            csr[SSTATUS][XLEN-1:9],
            1'b0,  // SPP = 0
            csr[SSTATUS][7:6],
            1'b1,  // SPIE = 1
            csr[SSTATUS][4:2],
            csr[SSTATUS][`YSYX_CSR_MSTATUS_SPIE],  // SIE <- SPIE
            csr[SSTATUS][0]
          };
        end else if (rou_csr.ebreak) begin
          if (ebreak_deleg) begin
            // Delegate to S-mode
            csr[SEPC___] <= rou_csr.pc;
            csr[SCAUSE_] <= `YSYX_CAUSE_BREAKPOINT;
            csr[STVAL__] <= rou_csr.pc;
            csr[MSTATUS][`YSYX_CSR_MSTATUS_SPIE] <= csr[MSTATUS][`YSYX_CSR_MSTATUS_SIE_];
            csr[SSTATUS][`YSYX_CSR_MSTATUS_SPIE] <= csr[SSTATUS][`YSYX_CSR_MSTATUS_SIE_];
            csr[MSTATUS][`YSYX_CSR_MSTATUS_SIE_] <= 'h0;
            csr[SSTATUS][`YSYX_CSR_MSTATUS_SIE_] <= 'h0;
            if (priv_mode == `YSYX_PRIV_S) begin
              csr[MSTATUS][`YSYX_CSR_MSTATUS_SPP_] <= 'h1;
              csr[SSTATUS][`YSYX_CSR_MSTATUS_SPP_] <= 'h1;
            end
            priv_mode <= `YSYX_PRIV_S;
          end else begin
            // Handle in M-mode
            priv_mode <= `YSYX_PRIV_M;
            csr[MCAUSE_] <= `YSYX_CAUSE_BREAKPOINT;
            csr[MSTATUS][`YSYX_CSR_MSTATUS_MPP_] <= priv_mode;
            csr[MSTATUS][`YSYX_CSR_MSTATUS_MPIE] <= mstatus_mie;
            csr[MSTATUS][`YSYX_CSR_MSTATUS_MIE_] <= 1'b0;
            csr[MEPC___] <= rou_csr.pc;
            csr[MTVAL__] <= rou_csr.pc;
          end
        end else if (rou_csr.trap) begin
          if (smode_handle) begin
            csr[STVAL__] <= rou_csr.tval;
            csr[SEPC___] <= rou_csr.pc;
            csr[SCAUSE_] <= rou_csr.cause;

            csr[MSTATUS][`YSYX_CSR_MSTATUS_SIE_] <= 'h0;
            csr[SSTATUS][`YSYX_CSR_MSTATUS_SIE_] <= 'h0;

            csr[MSTATUS][`YSYX_CSR_MSTATUS_SPIE] <= csr[MSTATUS][`YSYX_CSR_MSTATUS_SIE_];
            csr[SSTATUS][`YSYX_CSR_MSTATUS_SPIE] <= csr[SSTATUS][`YSYX_CSR_MSTATUS_SIE_];

            if (priv_mode == `YSYX_PRIV_S) begin
              csr[MSTATUS][`YSYX_CSR_MSTATUS_SPP_] <= 'h1;
              csr[SSTATUS][`YSYX_CSR_MSTATUS_SPP_] <= 'h1;
            end

            priv_mode <= `YSYX_PRIV_S;
          end else begin
            csr[MCAUSE_] <= rou_csr.cause;

            csr[MSTATUS][`YSYX_CSR_MSTATUS_MPP_] <= priv_mode;
            csr[MSTATUS][`YSYX_CSR_MSTATUS_MPIE] <= mstatus_mie;
            csr[MSTATUS][`YSYX_CSR_MSTATUS_MIE_] <= 1'b0;

            csr[MEPC___] <= rou_csr.pc;
            csr[MTVAL__] <= rou_csr.tval;
            priv_mode <= `YSYX_PRIV_M;
          end
        end
      end
    end
  end
endmodule

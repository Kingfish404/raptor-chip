`include "ysyx.svh"
`include "ysyx_if.svh"
`include "ysyx_dpi_c.svh"

module ysyx_csr #(
    parameter bit [7:0] XLEN = `YSYX_XLEN,
    parameter bit [7:0] R_W = 12,
    parameter bit [7:0] REG_W = 5,
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
    TIME___,
    TIMEH__,

    MVENDORID,
    MARCHID,
    IMPID__,
    MHARTID
  } csr_t;

  logic [1:0] priv_mode;
  logic [XLEN-1:0] csr[32];
  logic mstatus_mie;
  csr_t waddr_reg, raddr_reg;
  logic [R_W-1:0] raddr;

  // trap handle
  logic [XLEN-1:0] cause_idx;
  logic smode_medeleg;
  logic smode_mideleg;
  logic smode_handle;

  assign raddr = exu_csr.raddr;
  assign waddr_reg = csr_t'(
      ({REG_W{rou_csr.csr_addr==`YSYX_CSR_SSTATUS}}) & (SSTATUS)
    | ({REG_W{rou_csr.csr_addr==`YSYX_CSR_SIE____}}) & (SIE____)
    | ({REG_W{rou_csr.csr_addr==`YSYX_CSR_STVEC__}}) & (STVEC__)

    | ({REG_W{rou_csr.csr_addr==`YSYX_CSR_SCOUNTE}}) & (SCOUNTE)

    | ({REG_W{rou_csr.csr_addr==`YSYX_CSR_SSCRATC}}) & (SSCRATC)
    | ({REG_W{rou_csr.csr_addr==`YSYX_CSR_SEPC___}}) & (SEPC___)
    | ({REG_W{rou_csr.csr_addr==`YSYX_CSR_SCAUSE_}}) & (SCAUSE_)
    | ({REG_W{rou_csr.csr_addr==`YSYX_CSR_STVAL__}}) & (STVAL__)
    | ({REG_W{rou_csr.csr_addr==`YSYX_CSR_SIP____}}) & (SIP____)
    | ({REG_W{rou_csr.csr_addr==`YSYX_CSR_SATP___}}) & (SATP___)

    | ({REG_W{rou_csr.csr_addr==`YSYX_CSR_MSTATUS}}) & (MSTATUS)
    | ({REG_W{rou_csr.csr_addr==`YSYX_CSR_MEDELEG}}) & (MEDELEG)
    | ({REG_W{rou_csr.csr_addr==`YSYX_CSR_MIDELEG}}) & (MIDELEG)
    | ({REG_W{rou_csr.csr_addr==`YSYX_CSR_MIE____}}) & (MIE____)
    | ({REG_W{rou_csr.csr_addr==`YSYX_CSR_MTVEC__}}) & (MTVEC__)

    | ({REG_W{rou_csr.csr_addr==`YSYX_CSR_MSCRATCH}}) &(MSCRATCH)
    | ({REG_W{rou_csr.csr_addr==`YSYX_CSR_MEPC___}}) & (MEPC___)
    | ({REG_W{rou_csr.csr_addr==`YSYX_CSR_MCAUSE_}}) & (MCAUSE_)
    | ({REG_W{rou_csr.csr_addr==`YSYX_CSR_MTVAL__}}) & (MTVAL__)
    | ({REG_W{rou_csr.csr_addr==`YSYX_CSR_MIP____}}) & (MIP____)
    | (MNONE__)
  );
  assign raddr_reg = csr_t'(
      ({REG_W{raddr==`YSYX_CSR_SSTATUS}}) & (SSTATUS)
    | ({REG_W{raddr==`YSYX_CSR_SIE____}}) & (SIE____)
    | ({REG_W{raddr==`YSYX_CSR_STVEC__}}) & (STVEC__)

    | ({REG_W{raddr==`YSYX_CSR_SCOUNTE}}) & (SCOUNTE)

    | ({REG_W{raddr==`YSYX_CSR_SSCRATC}}) & (SSCRATC)
    | ({REG_W{raddr==`YSYX_CSR_SEPC___}}) & (SEPC___)
    | ({REG_W{raddr==`YSYX_CSR_SCAUSE_}}) & (SCAUSE_)
    | ({REG_W{raddr==`YSYX_CSR_STVAL__}}) & (STVAL__)
    | ({REG_W{raddr==`YSYX_CSR_SIP____}}) & (SIP____)
    | ({REG_W{raddr==`YSYX_CSR_SATP___}}) & (SATP___)

    | ({REG_W{raddr==`YSYX_CSR_MSTATUS}}) & (MSTATUS)
    | ({REG_W{raddr==`YSYX_CSR_MISA___}}) & (MISA___)
    | ({REG_W{raddr==`YSYX_CSR_MEDELEG}}) & (MEDELEG)
    | ({REG_W{raddr==`YSYX_CSR_MIDELEG}}) & (MIDELEG)
    | ({REG_W{raddr==`YSYX_CSR_MIE____}}) & (MIE____)
    | ({REG_W{raddr==`YSYX_CSR_MTVEC__}}) & (MTVEC__)

    | ({REG_W{raddr==`YSYX_CSR_MSCRATCH}}) & (MSCRATCH)
    | ({REG_W{raddr==`YSYX_CSR_MEPC___}}) & (MEPC___)
    | ({REG_W{raddr==`YSYX_CSR_MCAUSE_}}) & (MCAUSE_)
    | ({REG_W{raddr==`YSYX_CSR_MTVAL__}}) & (MTVAL__)
    | ({REG_W{raddr==`YSYX_CSR_MIP____}}) & (MIP____)

    | ({REG_W{raddr==`YSYX_CSR_MCYCLE_}}) & (MCYCLE_)
    | ({REG_W{raddr==`YSYX_CSR_MCYCLEH}}) & (MCYCLEH)
    | ({REG_W{raddr==`YSYX_CSR_CYCLE__}}) & (MCYCLE_)
    | ({REG_W{raddr==`YSYX_CSR_TIME___}}) & (TIME___)
    | ({REG_W{raddr==`YSYX_CSR_TIMEH__}}) & (TIMEH__)

    | ({REG_W{raddr==`YSYX_CSR_MVENDORID}}) & (MVENDORID)
    | ({REG_W{raddr==`YSYX_CSR_MARCHID__}}) & (MARCHID)
    | ({REG_W{raddr==`YSYX_CSR_IMPID____}}) & (IMPID__)
    | ({REG_W{raddr==`YSYX_CSR_MHARTID__}}) & (MHARTID)
    | (MNONE__)
  );

  assign exu_csr.rdata = (
      ({XLEN{raddr_reg == SSTATUS}}) & (csr[SSTATUS])
    | ({XLEN{raddr_reg == SIE____}}) & (csr[SIE____])
    | ({XLEN{raddr_reg == STVEC__}}) & (csr[STVEC__])

    | ({XLEN{raddr_reg == SCOUNTE}}) & (csr[SCOUNTE])

    | ({XLEN{raddr_reg == SSCRATC}}) & (csr[SSCRATC])
    | ({XLEN{raddr_reg == SEPC___}}) & (csr[SEPC___])
    | ({XLEN{raddr_reg == SCAUSE_}}) & (csr[SCAUSE_])
    | ({XLEN{raddr_reg == STVAL__}}) & (csr[STVAL__])
    | ({XLEN{raddr_reg == SIP____}}) & (csr[SIP____])
    | ({XLEN{raddr_reg == SATP___}}) & (csr[SATP___])

    | ({XLEN{raddr_reg == MSTATUS}}) & (csr[MSTATUS])
    | ({XLEN{raddr_reg == MISA___}}) & (`YSYX_MISA)
    | ({XLEN{raddr_reg == MEDELEG}}) & (csr[MEDELEG])
    | ({XLEN{raddr_reg == MIDELEG}}) & (csr[MIDELEG])
    | ({XLEN{raddr_reg == MIE____}}) & (csr[MIE____])
    | ({XLEN{raddr_reg == MTVEC__}}) & (csr[MTVEC__])

    | ({XLEN{raddr_reg == MSCRATCH}}) & (csr[MSCRATCH])
    | ({XLEN{raddr_reg == MEPC___}}) & (csr[MEPC___])
    | ({XLEN{raddr_reg == MCAUSE_}}) & (csr[MCAUSE_])
    | ({XLEN{raddr_reg == MTVAL__}}) & (csr[MTVAL__])
    | ({XLEN{raddr_reg == MIP____}}) & (csr[MIP____])

    | ({XLEN{raddr_reg == MCYCLE_}}) & (csr[MCYCLE_])
    | ({XLEN{raddr_reg == MCYCLEH}}) & (csr[MCYCLEH])
    | ({XLEN{raddr_reg == TIME___}}) & (csr[TIME___])
    | ({XLEN{raddr_reg == TIMEH__}}) & (csr[TIMEH__])

    | ({XLEN{raddr_reg == MVENDORID}}) & ('h79737978)
    | ({XLEN{raddr_reg == MARCHID}}) & ('h015fde77)
    | ({XLEN{raddr_reg == IMPID__}}) & ('h0)
    | ({XLEN{raddr_reg == MHARTID}}) & ('h0)
  );

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
  assign csr_bcast.tvec = smode_handle ? csr[STVEC__] : csr[MTVEC__];

  assign csr_bcast.interrupt_en = (
      (priv_mode == `YSYX_PRIV_M)
        ? csr[MSTATUS][`YSYX_CSR_MSTATUS_MIE_] && csr[MIE____][`YSYX_CSR_MIE_MTIE]
    : (priv_mode == `YSYX_PRIV_S)
        ? csr[SSTATUS][`YSYX_CSR_MSTATUS_SIE_] && csr[MIE____][`YSYX_CSR_MIE_STIE]
    : 'b0
  );

  always @(posedge clock) begin
    if (reset) begin
      priv_mode <= `YSYX_PRIV_M;
      csr[MCAUSE_] <= RESET_VAL;
      csr[MEPC___] <= RESET_VAL;
      csr[MTVEC__] <= RESET_VAL;
      csr[MSTATUS] <= RESET_VAL;
      csr[TIME___] <= RESET_VAL;
      csr[TIMEH__] <= RESET_VAL;
    end else begin
      csr[TIME___] <= csr[TIME___] + 1;
      if (csr[TIME___] == ~'h0) begin
        csr[TIMEH__] <= csr[TIMEH__] + 1;
      end
      csr[MCYCLE_] <= csr[MCYCLE_] + 1;
      if (csr[MCYCLE_] == ~'h0) begin
        csr[MCYCLEH] <= csr[MCYCLEH] + 1;
      end
      if (rou_csr.valid) begin
        if (raddr_reg == TIME___
         || raddr_reg == TIMEH__
         || raddr_reg == MCYCLE_
         || raddr_reg == MCYCLEH
        ) begin
          `YSYX_DPI_C_NPC_DIFFTEST_SKIP_REF
        end
        if (rou_csr.csr_wen) begin
          if (waddr_reg == MEDELEG) begin
            csr[waddr_reg] <= (rou_csr.csr_wdata & 'hf4bfff);
          end else begin
            csr[waddr_reg] <= (rou_csr.csr_wdata);
            if (waddr_reg == MSTATUS) begin
              csr[SSTATUS] <= rou_csr.csr_wdata & 'h800de762;
            end else if (waddr_reg == SIE____) begin
              csr[MIE____] <= csr[MIE____] | (rou_csr.csr_wdata);
            end else if (waddr_reg == SSTATUS) begin
              csr[MSTATUS] <= (csr[MSTATUS] & ~'h800DE752) | (rou_csr.csr_wdata & 'h800DE752);
            end
          end
        end
        if (rou_csr.ecall) begin
          priv_mode <= `YSYX_PRIV_M;
          csr[MCAUSE_] <= priv_mode == `YSYX_PRIV_M ? 'hb : priv_mode == `YSYX_PRIV_S ? 'h9 : 'h8;
          csr[MSTATUS][`YSYX_CSR_MSTATUS_MPP_] <= priv_mode;
          csr[MSTATUS][`YSYX_CSR_MSTATUS_MPIE] <= mstatus_mie;
          csr[MSTATUS][`YSYX_CSR_MSTATUS_MIE_] <= 1'b0;
          csr[MEPC___] <= rou_csr.pc;
          csr[MTVAL__] <= 0;
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
          csr[MSTATUS][`YSYX_CSR_MSTATUS_SIE_] <= 'b1;
          csr[SSTATUS][`YSYX_CSR_MSTATUS_SIE_] <= 'b1;

          csr[MSTATUS][`YSYX_CSR_MSTATUS_SPP_] <= 'b0;
          csr[SSTATUS][`YSYX_CSR_MSTATUS_SPP_] <= 'b0;
        end else if (rou_csr.ebreak) begin
          priv_mode <= `YSYX_PRIV_M;
          csr[MCAUSE_] <= 'h3;
          csr[MSTATUS][`YSYX_CSR_MSTATUS_MPP_] <= priv_mode;
          csr[MSTATUS][`YSYX_CSR_MSTATUS_MPIE] <= mstatus_mie;
          csr[MSTATUS][`YSYX_CSR_MSTATUS_MIE_] <= 1'b0;
          csr[MEPC___] <= rou_csr.pc;
          csr[MTVAL__] <= rou_csr.pc;
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

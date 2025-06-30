`include "ysyx.svh"
`include "ysyx_if.svh"
`include "ysyx_dpi_c.svh"

module ysyx_csr #(
    parameter bit [7:0] R_W = 12,
    parameter bit [7:0] REG_W = 5,
    parameter bit [XLEN-1:0] RESET_VAL = 0,
    parameter bit [7:0] XLEN = `YSYX_XLEN
) (
    input clock,

    input wen,
    input valid,
    input ecall,
    input mret,
    input ebreak,

    input [ R_W-1:0] waddr,
    input [XLEN-1:0] wdata,
    input [XLEN-1:0] pc,

    input trap,
    input [XLEN-1:0] tval,
    input [XLEN-1:0] cause,

    exu_csr_if.slave exu_csr,


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
  assign raddr = exu_csr.raddr;
  assign waddr_reg = csr_t'(
    ({REG_W{waddr==`YSYX_CSR_SSTATUS}}) & (SSTATUS) |
    ({REG_W{waddr==`YSYX_CSR_SIE____}}) & (SIE____) |
    ({REG_W{waddr==`YSYX_CSR_STVEC__}}) & (STVEC__) |

    ({REG_W{waddr==`YSYX_CSR_SCOUNTE}}) & (SCOUNTE) |

    ({REG_W{waddr==`YSYX_CSR_SSCRATC}}) & (SSCRATC) |
    ({REG_W{waddr==`YSYX_CSR_SEPC___}}) & (SEPC___) |
    ({REG_W{waddr==`YSYX_CSR_SCAUSE_}}) & (SCAUSE_) |
    ({REG_W{waddr==`YSYX_CSR_STVAL__}}) & (STVAL__) |
    ({REG_W{waddr==`YSYX_CSR_SIP____}}) & (SIP____) |
    ({REG_W{waddr==`YSYX_CSR_SATP___}}) & (SATP___) |

    ({REG_W{waddr==`YSYX_CSR_MSTATUS}}) & (MSTATUS) |
    ({REG_W{waddr==`YSYX_CSR_MEDELEG}}) & (MEDELEG) |
    ({REG_W{waddr==`YSYX_CSR_MIDELEG}}) & (MIDELEG) |
    ({REG_W{waddr==`YSYX_CSR_MIE____}}) & (MIE____) |
    ({REG_W{waddr==`YSYX_CSR_MTVEC__}}) & (MTVEC__) |

    ({REG_W{waddr==`YSYX_CSR_MSCRATCH}}) &(MSCRATCH) |
    ({REG_W{waddr==`YSYX_CSR_MEPC___}}) & (MEPC___) |
    ({REG_W{waddr==`YSYX_CSR_MCAUSE_}}) & (MCAUSE_) |
    ({REG_W{waddr==`YSYX_CSR_MTVAL__}}) & (MTVAL__) |
    ({REG_W{waddr==`YSYX_CSR_MIP____}}) & (MIP____) |
    (MNONE__)
  );
  assign raddr_reg = csr_t'(
    ({REG_W{raddr==`YSYX_CSR_SSTATUS}}) & (SSTATUS) |
    ({REG_W{raddr==`YSYX_CSR_SIE____}}) & (SIE____) |
    ({REG_W{raddr==`YSYX_CSR_STVEC__}}) & (STVEC__) |

    ({REG_W{raddr==`YSYX_CSR_SCOUNTE}}) & (SCOUNTE) |

    ({REG_W{raddr==`YSYX_CSR_SSCRATC}}) & (SSCRATC) |
    ({REG_W{raddr==`YSYX_CSR_SEPC___}}) & (SEPC___) |
    ({REG_W{raddr==`YSYX_CSR_SCAUSE_}}) & (SCAUSE_) |
    ({REG_W{raddr==`YSYX_CSR_STVAL__}}) & (STVAL__) |
    ({REG_W{raddr==`YSYX_CSR_SIP____}}) & (SIP____) |
    ({REG_W{raddr==`YSYX_CSR_SATP___}}) & (SATP___) |

    ({REG_W{raddr==`YSYX_CSR_MSTATUS}}) & (MSTATUS) |
    ({REG_W{raddr==`YSYX_CSR_MISA___}}) & (MISA___) |
    ({REG_W{raddr==`YSYX_CSR_MEDELEG}}) & (MEDELEG) |
    ({REG_W{raddr==`YSYX_CSR_MIDELEG}}) & (MIDELEG) |
    ({REG_W{raddr==`YSYX_CSR_MIE____}}) & (MIE____) |
    ({REG_W{raddr==`YSYX_CSR_MTVEC__}}) & (MTVEC__) |

    ({REG_W{raddr==`YSYX_CSR_MSCRATCH}}) & (MSCRATCH) |
    ({REG_W{raddr==`YSYX_CSR_MEPC___}}) & (MEPC___) |
    ({REG_W{raddr==`YSYX_CSR_MCAUSE_}}) & (MCAUSE_) |
    ({REG_W{raddr==`YSYX_CSR_MTVAL__}}) & (MTVAL__) |
    ({REG_W{raddr==`YSYX_CSR_MIP____}}) & (MIP____) |

    ({REG_W{raddr==`YSYX_CSR_MCYCLE_}}) & (MCYCLE_) |
    ({REG_W{raddr==`YSYX_CSR_TIME___}}) & (TIME___) |
    ({REG_W{raddr==`YSYX_CSR_TIMEH__}}) & (TIMEH__) |

    ({REG_W{raddr==`YSYX_CSR_MVENDORID}}) & (MVENDORID) |
    ({REG_W{raddr==`YSYX_CSR_MARCHID__}}) & (MARCHID) |
    ({REG_W{raddr==`YSYX_CSR_IMPID____}}) & (IMPID__) |
    ({REG_W{raddr==`YSYX_CSR_MHARTID__}}) & (MHARTID) |
    (MNONE__)
  );

  assign exu_csr.rdata = (
    ({XLEN{raddr_reg == SSTATUS}}) & (csr[SSTATUS]) |
    ({XLEN{raddr_reg == SIE____}}) & (csr[SIE____]) |
    ({XLEN{raddr_reg == STVEC__}}) & (csr[STVEC__]) |

    ({XLEN{raddr_reg == SCOUNTE}}) & (csr[SCOUNTE]) |

    ({XLEN{raddr_reg == SSCRATC}}) & (csr[SSCRATC]) |
    ({XLEN{raddr_reg == SEPC___}}) & (csr[SEPC___]) |
    ({XLEN{raddr_reg == SCAUSE_}}) & (csr[SCAUSE_]) |
    ({XLEN{raddr_reg == STVAL__}}) & (csr[STVAL__]) |
    ({XLEN{raddr_reg == SIP____}}) & (csr[SIP____]) |
    ({XLEN{raddr_reg == SATP___}}) & (csr[SATP___]) |

    ({XLEN{raddr_reg == MSTATUS}}) & (csr[MSTATUS]) |
    ({XLEN{raddr_reg == MISA___}}) & ('h40141101) |
    ({XLEN{raddr_reg == MEDELEG}}) & (csr[MEDELEG]) |
    ({XLEN{raddr_reg == MIDELEG}}) & (csr[MIDELEG]) |
    ({XLEN{raddr_reg == MIE____}}) & (csr[MIE____]) |
    ({XLEN{raddr_reg == MTVEC__}}) & (csr[MTVEC__]) |

    ({XLEN{raddr_reg == MSCRATCH}}) & (csr[MSCRATCH]) |
    ({XLEN{raddr_reg == MEPC___}}) & (csr[MEPC___]) |
    ({XLEN{raddr_reg == MCAUSE_}}) & (csr[MCAUSE_]) |
    ({XLEN{raddr_reg == MTVAL__}}) & (csr[MTVAL__]) |
    ({XLEN{raddr_reg == MIP____}}) & (csr[MIP____]) |

    ({XLEN{raddr_reg == MCYCLE_}}) & (csr[MCYCLE_]) |
    ({XLEN{raddr_reg == TIME___}}) & (csr[TIME___]) |
    ({XLEN{raddr_reg == TIMEH__}}) & (csr[TIMEH__]) |

    ({XLEN{raddr_reg == MVENDORID}}) & ('h79737978) |
    ({XLEN{raddr_reg == MARCHID}}) & ('h015fde77) |
    ({XLEN{raddr_reg == IMPID__}}) & ('h0) |
    ({XLEN{raddr_reg == MHARTID}}) & ('h0) |
    (0)
  );

  assign exu_csr.mepc = csr[MEPC___];
  assign exu_csr.mtvec = csr[MTVEC__];

  assign mstatus_mie = csr[MSTATUS][`YSYX_CSR_MSTATUS_MIE_];

  always @(posedge clock) begin
    if (reset) begin
      priv_mode <= `YSYX_PRIV_M;
      csr[MCAUSE_]  <= RESET_VAL;
      csr[MEPC___]    <= RESET_VAL;
      csr[MTVEC__]   <= RESET_VAL;
      csr[MSTATUS] <= RESET_VAL;
      csr[TIME___] <= RESET_VAL;
      csr[TIMEH__] <= RESET_VAL;
    end else begin
      csr[TIME___] <= csr[TIME___] + 1;
      if (csr[TIME___] == 'hffffffff) begin
        csr[TIMEH__] <= csr[TIMEH__] + 1;
      end
      csr[MCYCLE_] <= csr[MCYCLE_] + 1;
      if (csr[MCYCLE_] == 'hffffffff) begin
        csr[TIMEH__] <= csr[TIMEH__] + 1;
      end
      if (valid) begin
        if (raddr_reg == TIME___ || raddr_reg == TIMEH__ || raddr_reg == MCYCLE_) begin
          `YSYX_DPI_C_NPC_DIFFTEST_SKIP_REF
        end
        if (wen) begin
          if (waddr_reg == MEDELEG) begin
            csr[waddr_reg] <= (wdata & 'h1ffff);
          end else begin
            csr[waddr_reg] <= wdata;
          end
        end
        if (ecall) begin
          csr[MCAUSE_] <= priv_mode == `YSYX_PRIV_M ? 'hb : priv_mode == `YSYX_PRIV_S ? 'h9 : 'h8;
          csr[MSTATUS][`YSYX_CSR_MSTATUS_MPP_] <= priv_mode;
          csr[MSTATUS][`YSYX_CSR_MSTATUS_MPIE] <= mstatus_mie;
          csr[MSTATUS][`YSYX_CSR_MSTATUS_MIE_] <= 1'b0;
          csr[MEPC___] <= pc;
          csr[MTVAL__] <= 0;
        end else if (mret) begin
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
        end else if (ebreak) begin
          csr[MCAUSE_] <= 'h3;
          csr[MSTATUS][`YSYX_CSR_MSTATUS_MPP_] <= priv_mode;
          csr[MSTATUS][`YSYX_CSR_MSTATUS_MPIE] <= mstatus_mie;
          csr[MSTATUS][`YSYX_CSR_MSTATUS_MIE_] <= 1'b0;
          csr[MEPC___] <= pc;
          csr[MTVAL__] <= pc;
        end else if (trap) begin
          csr[MCAUSE_] <= cause;
          csr[MSTATUS][`YSYX_CSR_MSTATUS_MPP_] <= priv_mode;
          csr[MSTATUS][`YSYX_CSR_MSTATUS_MPIE] <= mstatus_mie;
          csr[MSTATUS][`YSYX_CSR_MSTATUS_MIE_] <= 1'b0;
          csr[MEPC___] <= pc;
          csr[MTVAL__] <= tval;
        end
      end
    end
  end
endmodule

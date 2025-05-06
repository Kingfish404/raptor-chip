`include "ysyx.svh"

module ysyx_exu_csr #(
    parameter bit [7:0] XLEN = `YSYX_XLEN,
    parameter bit [7:0] R_W = 12,
    parameter bit [7:0] REG_W = 5,
    parameter bit [XLEN-1:0] RESET_VAL = 0
) (
    input clock,

    input wen,
    input valid,
    input ecall,
    input mret,

    input [ R_W-1:0] waddr,
    input [XLEN-1:0] wdata,
    input [XLEN-1:0] pc,

    input  [ R_W-1:0] raddr,
    output [XLEN-1:0] out_rdata,
    output [XLEN-1:0] out_mtvec,
    output [XLEN-1:0] out_mepc,

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
    TIMEH__
  } csr_t;

  logic [1:0] priv_mode;
  logic [XLEN-1:0] csr[32];
  csr_t waddr_reg0;
  assign waddr_reg0 = csr_t'(
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
    ({REG_W{waddr==`YSYX_CSR_MISA___}}) & (MISA___) |
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

  assign out_rdata = (
    ({XLEN{raddr==`YSYX_CSR_SSTATUS}}) & (csr[SSTATUS]) |
    ({XLEN{raddr==`YSYX_CSR_SIE____}}) & (csr[SIE____]) |
    ({XLEN{raddr==`YSYX_CSR_STVEC__}}) & (csr[STVEC__]) |

    ({XLEN{raddr==`YSYX_CSR_SCOUNTE}}) & (csr[SCOUNTE]) |

    ({XLEN{raddr==`YSYX_CSR_SSCRATC}}) & (csr[SSCRATC]) |
    ({XLEN{raddr==`YSYX_CSR_SEPC___}}) & (csr[SEPC___]) |
    ({XLEN{raddr==`YSYX_CSR_SCAUSE_}}) & (csr[SCAUSE_]) |
    ({XLEN{raddr==`YSYX_CSR_STVAL__}}) & (csr[STVAL__]) |
    ({XLEN{raddr==`YSYX_CSR_SIP____}}) & (csr[SIP____]) |
    ({XLEN{raddr==`YSYX_CSR_SATP___}}) & (csr[SATP___]) |

    ({XLEN{raddr==`YSYX_CSR_MSTATUS}}) & (csr[MSTATUS]) |
    ({XLEN{raddr==`YSYX_CSR_MISA___}}) & (csr[MISA___]) |
    ({XLEN{raddr==`YSYX_CSR_MEDELEG}}) & (csr[MEDELEG]) |
    ({XLEN{raddr==`YSYX_CSR_MIDELEG}}) & (csr[MIDELEG]) |
    ({XLEN{raddr==`YSYX_CSR_MIE____}}) & (csr[MIE____]) |
    ({XLEN{raddr==`YSYX_CSR_MTVEC__}}) & (csr[MTVEC__]) |

    ({XLEN{raddr==`YSYX_CSR_MSCRATCH}}) & (csr[MSCRATCH]) |
    ({XLEN{raddr==`YSYX_CSR_MEPC___}}) & (csr[MEPC___]) |
    ({XLEN{raddr==`YSYX_CSR_MCAUSE_}}) & (csr[MCAUSE_]) |
    ({XLEN{raddr==`YSYX_CSR_MTVAL__}}) & (csr[MTVAL__]) |
    ({XLEN{raddr==`YSYX_CSR_MIP____}}) & (csr[MIP____]) |

    ({XLEN{raddr==`YSYX_CSR_MVENDORID}}) & ('h79737978) |
    ({XLEN{raddr==`YSYX_CSR_MARCHID__}}) & ('h15fde77) |
    ({XLEN{raddr==`YSYX_CSR_IMPID____}}) & ('h0) |
    ({XLEN{raddr==`YSYX_CSR_MHARTID__}}) & ('h0) |
    (0)
  );

  assign out_mepc = csr[MEPC___];
  assign out_mtvec = csr[MTVEC__];

  logic mstatus_mie = csr[MSTATUS][`YSYX_CSR_MSTATUS_MIE_];

  always @(posedge clock) begin
    if (reset) begin
      priv_mode <= `YSYX_PRIV_M;
      csr[MCAUSE_]  <= RESET_VAL;
      csr[MEPC___]    <= RESET_VAL;
      csr[MTVEC__]   <= RESET_VAL;
      csr[MSTATUS] <= RESET_VAL;
    end else if (valid) begin
      if (wen) begin
        csr[waddr_reg0] <= wdata;
      end
      if (ecall) begin
        csr[MCAUSE_] <= priv_mode == `YSYX_PRIV_M ? 'hb : priv_mode == `YSYX_PRIV_S ? 'h9 : 'h8;
        csr[MSTATUS][`YSYX_CSR_MSTATUS_MPP_] <= priv_mode;
        csr[MSTATUS][`YSYX_CSR_MSTATUS_MPIE] <= mstatus_mie;
        csr[MSTATUS][`YSYX_CSR_MSTATUS_MIE_] <= 1'b0;
        csr[MEPC___] <= pc;
      end
      if (mret) begin
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
      end
    end
  end
endmodule

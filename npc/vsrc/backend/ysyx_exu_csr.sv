`include "ysyx.svh"

module ysyx_exu_csr #(
    parameter bit [7:0] XLEN = `YSYX_XLEN,
    parameter bit [7:0] R_W = 12,
    parameter bit [7:0] REG_W = 3,
    parameter bit [XLEN-1:0] RESET_VAL = 0
) (
    input clock,

    input wen,
    input exu_valid,
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

  localparam bit [REG_W-1:0] MNONE = 'h0;
  localparam bit [REG_W-1:0] MCAUSE = 'h1;
  localparam bit [REG_W-1:0] MEPC = 'h2;
  localparam bit [REG_W-1:0] MTVEC = 'h3;
  localparam bit [REG_W-1:0] MSTATUS = 'h4;

  logic [1:0] priv_mode;
  logic [XLEN-1:0] csr[5];
  logic [REG_W-1:0] waddr_reg0;
  assign waddr_reg0 = (
    ({REG_W{waddr==`YSYX_CSR_MCAUSE_}}) & (MCAUSE) |
    ({REG_W{waddr==`YSYX_CSR_MEPC___}}) & (MEPC) |
    ({REG_W{waddr==`YSYX_CSR_MTVEC__}}) & (MTVEC) |
    ({REG_W{waddr==`YSYX_CSR_MSTATUS}}) & (MSTATUS) |
    (MNONE)
  );

  assign out_rdata = (
    ({XLEN{raddr==`YSYX_CSR_MVENDORID}}) & ('h79737978) |
    ({XLEN{raddr==`YSYX_CSR_MARCHID__}}) & ('h15fde77) |
    ({XLEN{raddr==`YSYX_CSR_MSTATUS}}) & (csr[MSTATUS]) |
    ({XLEN{raddr==`YSYX_CSR_MCAUSE_}}) & (csr[MCAUSE]) |
    ({XLEN{raddr==`YSYX_CSR_MEPC___}}) & (csr[MEPC]) |
    ({XLEN{raddr==`YSYX_CSR_MTVEC__}}) & (csr[MTVEC]) |
    (0)
  );

  assign out_mepc = csr[MEPC];
  assign out_mtvec = csr[MTVEC];

  logic mstatus_mie = csr[MSTATUS][`YSYX_CSR_MSTATUS_MIE_];

  always @(posedge clock) begin
    if (reset) begin
      priv_mode <= `YSYX_PRIV_M;
      csr[MCAUSE]  <= RESET_VAL;
      csr[MEPC]    <= RESET_VAL;
      csr[MTVEC]   <= RESET_VAL;
      csr[MSTATUS] <= RESET_VAL;
    end else if (exu_valid) begin
      if (wen) begin
        csr[waddr_reg0] <= wdata;
      end
      if (ecall) begin
        csr[MCAUSE] <= priv_mode == `YSYX_PRIV_M ? 'hb : priv_mode == `YSYX_PRIV_S ? 'h9 : 'h8;
        csr[MSTATUS][`YSYX_CSR_MSTATUS_MPP_] <= priv_mode;
        csr[MSTATUS][`YSYX_CSR_MSTATUS_MPIE] <= mstatus_mie;
        csr[MSTATUS][`YSYX_CSR_MSTATUS_MIE_] <= 1'b0;
        csr[MEPC] <= pc;
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

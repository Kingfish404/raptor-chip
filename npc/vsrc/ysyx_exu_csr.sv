`include "ysyx_csr.svh"

module ysyx_exu_csr (
    input clk,
    input rst,

    input wen,
    input exu_valid,
    input ecallen,

    input [  R_W-1:0] waddr,
    input [  R_W-1:0] waddr_add1,
    input [BIT_W-1:0] wdata,
    input [BIT_W-1:0] wdata_add1,

    output [BIT_W-1:0] rdata_o,
    output [BIT_W-1:0] mtvec_o,
    output [BIT_W-1:0] mepc_o
);
  parameter bit [7:0] R_W = 12;
  parameter bit [7:0] REG_W = 3;
  parameter bit [7:0] BIT_W = `YSYX_W_WIDTH;
  parameter bit [BIT_W-1:0] RESET_VAL = 0;

  localparam bit [REG_W-1:0] MNONE = 'h0;
  localparam bit [REG_W-1:0] MCAUSE = 'h1;
  localparam bit [REG_W-1:0] MEPC = 'h2;
  localparam bit [REG_W-1:0] MTVEC = 'h3;
  localparam bit [REG_W-1:0] MSTATUS = 'h4;

  reg [BIT_W-1:0] csr[5];
  wire [REG_W-1:0] waddr_reg_1 = (
    ({REG_W{waddr==`YSYX_CSR_MCAUSE}}) & (MCAUSE) |
    ({REG_W{waddr==`YSYX_CSR_MEPC}}) & (MEPC) |
    ({REG_W{waddr==`YSYX_CSR_MTVEC}}) & (MTVEC) |
    ({REG_W{waddr==`YSYX_CSR_MSTATUS}}) & (MSTATUS) |
    (MNONE)
  );
  wire [REG_W-1:0] waddr_reg_2 = (
    ({REG_W{waddr_add1==`YSYX_CSR_MCAUSE}}) & (MCAUSE) |
    ({REG_W{waddr_add1==`YSYX_CSR_MEPC}}) & (MEPC) |
    ({REG_W{waddr_add1==`YSYX_CSR_MTVEC}}) & (MTVEC) |
    ({REG_W{waddr_add1==`YSYX_CSR_MSTATUS}}) & (MSTATUS) |
    (MNONE)
  );

  assign rdata_o = (
           ({BIT_W{waddr==`YSYX_CSR_MVENDORID}}) & (32'h79737978) |
           ({BIT_W{waddr==`YSYX_CSR_MARCHID}}) & (32'h15fde77) |
           ({BIT_W{waddr==`YSYX_CSR_MSTATUS}}) & (csr[MSTATUS]) |
           ({BIT_W{waddr==`YSYX_CSR_MCAUSE}}) & (csr[MCAUSE]) |
           ({BIT_W{waddr==`YSYX_CSR_MEPC}}) & (csr[MEPC]) |
           ({BIT_W{waddr==`YSYX_CSR_MTVEC}}) & (csr[MTVEC])
         );

  assign mepc_o = csr[MEPC];
  assign mtvec_o = csr[MTVEC];

  always @(posedge clk) begin
    if (rst) begin
      csr[MCAUSE]  <= RESET_VAL;
      csr[MEPC]    <= RESET_VAL;
      csr[MTVEC]   <= RESET_VAL;
      csr[MSTATUS] <= RESET_VAL;
    end else begin
      if (wen & exu_valid) begin
        $display("csr[%0d] <= %0d", waddr_reg_1, wdata);
        csr['b11] <= wdata;
        csr[waddr_reg_2] <= wdata_add1;
      end
      if (ecallen & exu_valid) begin
        csr[MSTATUS][`YSYX_CSR_MSTATUS_MPIE_IDX] <= csr[MSTATUS][`YSYX_CSR_MSTATUS_MIE_IDX];
        csr[MSTATUS][`YSYX_CSR_MSTATUS_MIE_IDX]  <= 1'b0;
      end
    end
  end
endmodule  //YSYX_CSR_Reg

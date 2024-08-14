`include "ysyx_macro.vh"
`include "ysyx_macro_csr.vh"

module ysyx_exu_csr (
    input clk,
    rst,
    input wen,
    exu_valid,
    input ecallen,
    input [R_W-1:0] waddr,
    waddr_add1,
    input [BIT_W-1:0] wdata,
    wdata_add1,
    output reg [BIT_W-1:0] rdata_o,
    output [BIT_W-1:0] mtvec_o,
    output [BIT_W-1:0] mepc_o
);
  parameter bit[7:0] R_W = 12;
  parameter bit[7:0] REG_W = 3;
  parameter bit[7:0] BIT_W = `YSYX_W_WIDTH;
  parameter bit[BIT_W-1:0] RESET_VAL = 0;

  parameter bit[REG_W-1:0] MNONE = 'h0;
  parameter bit[REG_W-1:0] MCAUSE_IDX = 'h1;
  parameter bit[REG_W-1:0] MEPC_IDX = 'h2;
  parameter bit[REG_W-1:0] MTVEC_IDX = 'h3;
  parameter bit[REG_W-1:0] MSTATUS_IDX = 'h4;

  reg [BIT_W-1:0] csr[5];
  wire [REG_W-1:0] waddr_reg_1 = (
    ({REG_W{waddr==`YSYX_CSR_MCAUSE}}) & (MCAUSE_IDX) |
    ({REG_W{waddr==`YSYX_CSR_MEPC}}) & (MEPC_IDX) |
    ({REG_W{waddr==`YSYX_CSR_MTVEC}}) & (MTVEC_IDX) |
    ({REG_W{waddr==`YSYX_CSR_MSTATUS}}) & (MSTATUS_IDX) |
    (MNONE)
  );
  wire [REG_W-1:0] waddr_reg_2 = (
    ({REG_W{waddr_add1==`YSYX_CSR_MCAUSE}}) & (MCAUSE_IDX) |
    ({REG_W{waddr_add1==`YSYX_CSR_MEPC}}) & (MEPC_IDX) |
    ({REG_W{waddr_add1==`YSYX_CSR_MTVEC}}) & (MTVEC_IDX) |
    ({REG_W{waddr_add1==`YSYX_CSR_MSTATUS}}) & (MSTATUS_IDX) |
    (MNONE)
  );

  assign rdata_o = (
           ({BIT_W{waddr==`YSYX_CSR_MVENDORID}}) & (32'h79737978) |
           ({BIT_W{waddr==`YSYX_CSR_MARCHID}}) & (32'h15fde77) |
           ({BIT_W{waddr==`YSYX_CSR_MSTATUS}}) & (csr[MSTATUS_IDX]) |
           ({BIT_W{waddr==`YSYX_CSR_MCAUSE}}) & (csr[MCAUSE_IDX]) |
           ({BIT_W{waddr==`YSYX_CSR_MEPC}}) & (csr[MEPC_IDX]) |
           ({BIT_W{waddr==`YSYX_CSR_MTVEC}}) & (csr[MTVEC_IDX])
         );

  assign mepc_o = csr[MEPC_IDX];
  assign mtvec_o = csr[MTVEC_IDX];

  always @(posedge clk) begin
    if (rst) begin
      csr[MCAUSE_IDX]  <= RESET_VAL;
      csr[MEPC_IDX]    <= RESET_VAL;
      csr[MTVEC_IDX]   <= RESET_VAL;
      csr[MSTATUS_IDX] <= RESET_VAL;
    end else if (exu_valid) begin
      if (wen) begin
        csr[waddr_reg_1] <= wdata;
        csr[waddr_reg_2] <= wdata_add1;
      end
      if (ecallen) begin
        csr[MSTATUS_IDX][`YSYX_CSR_MSTATUS_MPIE_IDX] <= csr[MSTATUS_IDX][`YSYX_CSR_MSTATUS_MIE_IDX];
        csr[MSTATUS_IDX][`YSYX_CSR_MSTATUS_MIE_IDX] <= 1'b0;
      end
    end
  end
endmodule  //YSYX_CSR_Reg

`include "ysyx_macro.v"
`include "ysyx_macro_csr.v"

module ysyx_CSR_Reg (
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
  parameter MCAUSE_IDX = 'h0;
  parameter MEPC_IDX = 'h1;
  parameter MTVEC_IDX = 'h2;
  parameter MSTATUS_IDX = 'h3;
  parameter MNONE = 'h4;

  parameter R_W = 12;
  parameter REG_W = 2;
  parameter BIT_W = `ysyx_W_WIDTH;
  parameter RESET_VAL = 0;

  reg [BIT_W-1:0] csr[4];
  wire [REG_W-1:0] waddr_reg1 = (
    ({REG_W{waddr==`ysyx_CSR_MSTATUS}}) & (MSTATUS_IDX) |
    ({REG_W{waddr==`ysyx_CSR_MCAUSE}}) & (MCAUSE_IDX) |
    ({REG_W{waddr==`ysyx_CSR_MEPC}}) & (MEPC_IDX) |
    ({REG_W{waddr==`ysyx_CSR_MTVEC}}) & (MTVEC_IDX)
  );
  wire [REG_W-1:0] waddr_reg2 = (
    ({REG_W{waddr_add1==`ysyx_CSR_MSTATUS}}) & (MSTATUS_IDX) |
    ({REG_W{waddr_add1==`ysyx_CSR_MCAUSE}}) & (MCAUSE_IDX) |
    ({REG_W{waddr_add1==`ysyx_CSR_MEPC}}) & (MEPC_IDX) |
    ({REG_W{waddr_add1==`ysyx_CSR_MTVEC}}) & (MTVEC_IDX)
  );
  wire waddr_reg2_valid = (
    (waddr_add1 == `ysyx_CSR_MSTATUS) |
     (waddr_add1 == `ysyx_CSR_MCAUSE) |
      (waddr_add1 == `ysyx_CSR_MEPC) |
       (waddr_add1 == `ysyx_CSR_MTVEC));
  wire waddr_reg1_valid = (
    (waddr == `ysyx_CSR_MSTATUS) |
     (waddr == `ysyx_CSR_MCAUSE) |
      (waddr == `ysyx_CSR_MEPC) |
       (waddr == `ysyx_CSR_MTVEC));

  assign rdata_o = (
           ({BIT_W{waddr==`ysyx_CSR_MVENDORID}}) & (32'h79737978) |
           ({BIT_W{waddr==`ysyx_CSR_MARCHID}}) & (32'h15fde77) |
           ({BIT_W{waddr==`ysyx_CSR_MSTATUS}}) & (csr[MSTATUS_IDX]) |
           ({BIT_W{waddr==`ysyx_CSR_MCAUSE}}) & (csr[MCAUSE_IDX]) |
           ({BIT_W{waddr==`ysyx_CSR_MEPC}}) & (csr[MEPC_IDX]) |
           ({BIT_W{waddr==`ysyx_CSR_MTVEC}}) & (csr[MTVEC_IDX])
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
        if (waddr_reg1_valid) begin
          csr[waddr_reg1] <= wdata;
        end
        if (waddr_reg2_valid) begin
          csr[waddr_reg2] <= wdata_add1;
        end
      end
      if (ecallen) begin
        csr[MSTATUS_IDX][`ysyx_CSR_MSTATUS_MPIE_IDX] <= csr[MSTATUS_IDX][`ysyx_CSR_MSTATUS_MIE_IDX];
        csr[MSTATUS_IDX][`ysyx_CSR_MSTATUS_MIE_IDX] <= 1'b0;
      end
    end
  end
endmodule  //ysyx_CSR_Reg

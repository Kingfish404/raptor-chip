`include "ysyx_macro.v"
`include "ysyx_macro_csr.v"

module ysyx_CSR_Reg(
    input clk, rst,
    input wen, exu_valid,
    input ecallen,
    input [R_W-1:0] waddr, waddr_add1,
    input [BIT_W-1:0] wdata, wdata_add1,
    output reg [BIT_W-1:0] rdata_o,
    output [BIT_W-1:0] mtvec_o,
    output [BIT_W-1:0] mepc_o
  );
  parameter MNONE        = 'h0;
  parameter MCAUSE_IDX  = 'h1;
  parameter MEPC_IDX    = 'h2;
  parameter MTVEC_IDX   = 'h3;
  parameter MSTATUS_IDX = 'h4;

  parameter R_W = 12;
  parameter REG_W = 3;
  parameter BIT_W = `ysyx_W_WIDTH;
  parameter RESET_VAL = 0;

  reg [BIT_W-1:0] csr[5];
  wire [REG_W-1:0] waddr_reg_1 = (
    {{REG_W{waddr==`ysyx_CSR_MSTATUS}} & (MCAUSE_IDX)} |
    {{REG_W{waddr==`ysyx_CSR_MCAUSE}} & (MEPC_IDX)} |
    {{REG_W{waddr==`ysyx_CSR_MEPC}} & MTVEC_IDX} |
    {{REG_W{waddr==`ysyx_CSR_MTVEC}} & MSTATUS_IDX} |
    (MNONE)
  );
  wire [REG_W-1:0] waddr_reg_2 = (
    {{REG_W{waddr_add1==`ysyx_CSR_MSTATUS}} & (MCAUSE_IDX)} |
    {{REG_W{waddr_add1==`ysyx_CSR_MCAUSE}} & (MEPC_IDX)} |
    {{REG_W{waddr_add1==`ysyx_CSR_MEPC}} & MTVEC_IDX} |
    {{REG_W{waddr_add1==`ysyx_CSR_MTVEC}} & MSTATUS_IDX} |
    (MNONE)
  );

  assign rdata_o = (
           ({BIT_W{waddr==`ysyx_CSR_MVENDORID}}) & (32'h79737978) |
           ({BIT_W{waddr==`ysyx_CSR_MARCHID}}) & (32'h15fde77) |
           ({BIT_W{waddr==`ysyx_CSR_MSTATUS}}) & (csr[MSTATUS_IDX]) |
           ({BIT_W{waddr==`ysyx_CSR_MCAUSE}}) & (csr[MCAUSE_IDX]) |
           ({BIT_W{waddr==`ysyx_CSR_MEPC}}) & (csr[MEPC_IDX]) |
           ({BIT_W{waddr==`ysyx_CSR_MTVEC}}) & (csr[MTVEC_IDX])
         );

  assign mepc_o  = csr[MEPC_IDX];
  assign mtvec_o = csr[MTVEC_IDX];

  always @(posedge clk)
    begin
      if (rst)
        begin
          csr[MNONE]        <= RESET_VAL;
          csr[MCAUSE_IDX]   <= RESET_VAL;
          csr[MEPC_IDX]     <= RESET_VAL;
          csr[MTVEC_IDX]    <= RESET_VAL;
          csr[MSTATUS_IDX]  <= RESET_VAL;
        end
      else if (exu_valid)
        begin
          if (wen)
            begin
              csr[waddr_reg_1] <= wdata;
              csr[waddr_reg_2] <= wdata_add1;
              // case (waddr)
              //   `ysyx_CSR_MSTATUS:
              //     begin
              //       csr[MSTATUS_IDX] <= wdata;
              //     end
              //   `ysyx_CSR_MEPC:
              //     begin
              //       csr[MEPC_IDX] <= wdata;
              //     end
              //   `ysyx_CSR_MTVEC:
              //     begin
              //       csr[MTVEC_IDX] <= wdata;
              //     end
              //   `ysyx_CSR_MCAUSE:
              //     begin
              //       csr[MCAUSE_IDX] <= wdata;
              //     end
              // endcase
              // case (waddr_add1)
              //   `ysyx_CSR_MSTATUS:
              //     begin
              //       csr[MSTATUS_IDX] <= wdata_add1;
              //     end
              //   `ysyx_CSR_MEPC:
              //     begin
              //       csr[MEPC_IDX] <= wdata_add1;
              //     end
              //   `ysyx_CSR_MTVEC:
              //     begin
              //       csr[MTVEC_IDX] <= wdata_add1;
              //     end
              //   `ysyx_CSR_MCAUSE:
              //     begin
              //       csr[MCAUSE_IDX] <= wdata_add1;
              //     end
              // endcase
            end
          if (ecallen)
            begin
              csr[MSTATUS_IDX][`ysyx_CSR_MSTATUS_MPIE_IDX] <= csr[MSTATUS_IDX][`ysyx_CSR_MSTATUS_MIE_IDX];
              csr[MSTATUS_IDX][`ysyx_CSR_MSTATUS_MIE_IDX] <= 1'b0;
            end
        end
    end
endmodule //ysyx_CSR_Reg

`include "ysyx_macro.v"
`include "ysyx_macro_csr.v"

module ysyx_CSR_Reg(
    input clk, rst,
    input wen, exu_valid,
    input ecallen,
    input [R_W-1:0] waddr, waddr_add1,
    input [BIT_W-1:0] wdata, wdata_add1,
    output reg [BIT_W-1:0] rdata_o,
    output reg [BIT_W-1:0] mtvec_o,
    output reg [BIT_W-1:0] mepc_o
  );
  parameter MNONE        = 'h0;
  parameter MCAUSE_IDX  = 'h1;
  parameter MEPC_IDX    = 'h2;
  parameter MTVEC_IDX   = 'h3;
  parameter MSTATUS_IDX = 'h4;

  parameter R_W = 12;
  parameter BIT_W = `ysyx_W_WIDTH;
  parameter RESET_VAL = 0;
  wire [2:0] csr_addr;
  wire [2:0] csr_addr_add1;
  assign rdata_o = (
           ({32{waddr==`ysyx_CSR_MVENDORID}})& (32'h79737978) |
           ({32{waddr==`ysyx_CSR_MARCHID}})& (32'h15fde77) |
           ({32{waddr==`ysyx_CSR_MSTATUS}})& (csr[MSTATUS_IDX]) |
           ({32{waddr==`ysyx_CSR_MCAUSE}})& (csr[MCAUSE_IDX]) |
           ({32{waddr==`ysyx_CSR_MEPC}})& (csr[MEPC_IDX]) |
           ({32{waddr==`ysyx_CSR_MTVEC}})& (csr[MTVEC_IDX])
         );
  assign mepc_o  = csr[MEPC_IDX];
  assign mtvec_o = csr[MTVEC_IDX];

  reg [BIT_W-1:0] csr[0:4];
  always @(posedge clk)
    begin
      if (rst)
        begin
          csr[MCAUSE_IDX]   <= RESET_VAL;
          csr[MEPC_IDX]     <= RESET_VAL;
          csr[MTVEC_IDX]    <= RESET_VAL;
          csr[MSTATUS_IDX]  <= RESET_VAL;
        end
      else
        begin
          if (exu_valid && wen)
            begin
              case (waddr)
                `ysyx_CSR_MSTATUS:
                  begin
                    csr[MSTATUS_IDX] <= wdata;
                  end
                `ysyx_CSR_MEPC:
                  begin
                    csr[MEPC_IDX] <= wdata;
                  end
                `ysyx_CSR_MTVEC:
                  begin
                    csr[MTVEC_IDX] <= wdata;
                  end
                `ysyx_CSR_MCAUSE:
                  begin
                    csr[MCAUSE_IDX] <= wdata;
                  end
              endcase
              case (waddr_add1)
                `ysyx_CSR_MSTATUS:
                  begin
                    csr[MSTATUS_IDX] <= wdata_add1;
                  end
                `ysyx_CSR_MEPC:
                  begin
                    csr[MEPC_IDX] <= wdata_add1;
                  end
                `ysyx_CSR_MTVEC:
                  begin
                    csr[MTVEC_IDX] <= wdata_add1;
                  end
                `ysyx_CSR_MCAUSE:
                  begin
                    csr[MCAUSE_IDX] <= wdata_add1;
                  end
              endcase
            end
          if (exu_valid && ecallen)
            begin
              csr[MSTATUS_IDX][`ysyx_CSR_MSTATUS_MPIE_IDX] <= csr[MSTATUS_IDX][`ysyx_CSR_MSTATUS_MIE_IDX];
              csr[MSTATUS_IDX][`ysyx_CSR_MSTATUS_MIE_IDX] <= 1'b0;
            end
        end
    end
endmodule //ysyx_CSR_Reg

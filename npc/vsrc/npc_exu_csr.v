`include "npc_macro.v"
`include "npc_macro_csr.v"

module ysyx_CSR_Reg(
  input clk, rst,
  input wen, exu_valid,
  input ecallen,
  input [R_W-1:0] waddr, waddr_add1,
  input [BIT_W-1:0] wdata, wdata_add1,
  output reg [BIT_W-1:0] rdata_o,
  output wire [BIT_W-1:0] mtvec_o,
  output wire [BIT_W-1:0] mepc_o
);
  parameter MNONE        = 'h0;
  parameter MCAUSE_IDX  = 'h1;
  parameter MEPC_IDX    = 'h2;
  parameter MTVEC_IDX   = 'h3;
  parameter MSTATUS_IDX = 'h4;

  parameter R_W = 12;
  parameter BIT_W = `ysyx_W_WIDTH;
  parameter RESET_VAL = 0;
  reg [2:0] csr_addr;
  reg [2:0] csr_addr_add1;
  reg [BIT_W-1:0] csr[0:7];
  assign rdata_o = csr[csr_addr];
  assign mepc_o  = csr[MEPC_IDX];
  assign mtvec_o = csr[MTVEC_IDX];

  always @(*) begin
    case (waddr)
      `ysyx_CSR_MCAUSE:   begin csr_addr = MCAUSE_IDX;  end
      `ysyx_CSR_MEPC:     begin csr_addr = MEPC_IDX;    end
      `ysyx_CSR_MTVEC:    begin csr_addr = MTVEC_IDX;   end
      `ysyx_CSR_MSTATUS:  begin csr_addr = MSTATUS_IDX; end
      default: begin  csr_addr = MNONE; end
    endcase
    case (waddr_add1)
      `ysyx_CSR_MCAUSE:   begin csr_addr_add1 = MCAUSE_IDX;  end
      `ysyx_CSR_MEPC:     begin csr_addr_add1 = MEPC_IDX;    end
      `ysyx_CSR_MTVEC:    begin csr_addr_add1 = MTVEC_IDX;   end
      `ysyx_CSR_MSTATUS:  begin csr_addr_add1 = MSTATUS_IDX; end
      default: begin  csr_addr_add1 = MNONE; end
    endcase
  end

  always @(posedge clk) begin
    if (rst) begin
      csr[MCAUSE_IDX]   <= RESET_VAL;
      csr[MEPC_IDX]     <= RESET_VAL;
      csr[MTVEC_IDX]    <= RESET_VAL;
      csr[MSTATUS_IDX]  <= RESET_VAL;
    end
    else begin
      if (exu_valid && wen) begin
        csr[csr_addr] <= wdata;
        csr[csr_addr_add1] <= wdata_add1;
      end
      if (exu_valid && ecallen) begin
        csr[MSTATUS_IDX][`ysyx_CSR_MSTATUS_MPIE_IDX] <= csr[MSTATUS_IDX][`ysyx_CSR_MSTATUS_MIE_IDX];
        csr[MSTATUS_IDX][`ysyx_CSR_MSTATUS_MIE_IDX] <= 1'b0;
      end
    end
  end
endmodule //ysyx_CSR_Reg 
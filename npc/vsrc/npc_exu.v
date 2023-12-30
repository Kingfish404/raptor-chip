import "DPI-C" function void npc_exu_ebreak ();
import "DPI-C" function void pmem_read (input int raddr, output int rdata);
import "DPI-C" function void pmem_write (
  input int waddr, input int wdata, input byte wmask);

`include "npc_macro.v"
`include "npc_macro_csr.v"

module ysyx_CSR_Reg(
  input clk,
  input rst,
  input wen,
  input ecallen,
  input [R_W-1:0] waddr,
  input [BIT_W-1:0] wdata,
  input [R_W-1:0] waddr_add1,
  input [BIT_W-1:0] wdata_add1,
  output reg [BIT_W-1:0] rdata_o,
  output wire [BIT_W-1:0] mtvec_o,
  output wire [BIT_W-1:0] mepc_o
);
  parameter CSR_NONE        = 'h0;
  parameter CSR_MCAUSE_IDX  = 'h1;
  parameter CSR_MEPC_IDX    = 'h2;
  parameter CSR_MTVEC_IDX   = 'h3;
  parameter CSR_MSTATUS_IDX = 'h4;

  parameter R_W = 12;
  parameter BIT_W = `ysyx_W_WIDTH;
  parameter RESET_VAL = 0;
  reg [2:0] csr_addr;
  reg [2:0] csr_addr_add1;
  reg [BIT_W-1:0] csr[0:7];
  assign rdata_o = csr[csr_addr];
  assign mepc_o  = csr[CSR_MEPC_IDX];
  assign mtvec_o = csr[CSR_MTVEC_IDX];

  always @(*) begin
    case (waddr)
      `ysyx_CSR_MCAUSE:   begin csr_addr = CSR_MCAUSE_IDX;  end
      `ysyx_CSR_MEPC:     begin csr_addr = CSR_MEPC_IDX;    end
      `ysyx_CSR_MTVEC:    begin csr_addr = CSR_MTVEC_IDX;   end
      `ysyx_CSR_MSTATUS:  begin csr_addr = CSR_MSTATUS_IDX; end
      default: begin  csr_addr = CSR_NONE; end
    endcase
    case (waddr_add1)
      `ysyx_CSR_MCAUSE:   begin csr_addr_add1 = CSR_MCAUSE_IDX;  end
      `ysyx_CSR_MEPC:     begin csr_addr_add1 = CSR_MEPC_IDX;    end
      `ysyx_CSR_MTVEC:    begin csr_addr_add1 = CSR_MTVEC_IDX;   end
      `ysyx_CSR_MSTATUS:  begin csr_addr_add1 = CSR_MSTATUS_IDX; end
      default: begin  csr_addr_add1 = CSR_NONE; end
    endcase
  end

  always @(posedge clk) begin
    if (rst) begin
      csr[CSR_MCAUSE_IDX]   <= RESET_VAL;
      csr[CSR_MEPC_IDX]     <= RESET_VAL;
      csr[CSR_MTVEC_IDX]    <= RESET_VAL;
      csr[CSR_MSTATUS_IDX]  <= RESET_VAL;
    end
    else if (wen) begin
      csr[csr_addr] <= wdata;
      csr[csr_addr_add1] <= wdata_add1;
    end
    if (ecallen) begin
      csr[CSR_MSTATUS_IDX][`ysyx_CSR_MSTATUS_MPIE_IDX] <= csr[CSR_MSTATUS_IDX][`ysyx_CSR_MSTATUS_MIE_IDX];
      csr[CSR_MSTATUS_IDX][`ysyx_CSR_MSTATUS_MIE_IDX] <= 1'b0;
    end
  end
endmodule //ysyx_CSR_Reg 

module ysyx_EXU (
  input wire clk,
  input wire rst,
  input wire [BIT_W-1:0] imm,
  input wire [BIT_W-1:0] op1, op2, op_j,
  input wire [3:0] alu_op,
  input wire [6:0] funct7, opcode,
  input wire [BIT_W-1:0] npc,
  output reg [BIT_W-1:0] reg_wdata_o,
  output reg [BIT_W-1:0] npc_wdata_o
);
  parameter BIT_W = `ysyx_W_WIDTH;

  wire [BIT_W-1:0] npc_wdata;
  wire [BIT_W-1:0] reg_wdata, mepc, mtvec;
  reg [BIT_W-1:0] mem_rdata;
  reg [31:0] mem_rdata_buf [0:1];
  reg [12-1:0]    csr_addr, csr_addr_add1;
  reg [BIT_W-1:0] csr_wdata, csr_wdata_add1, csr_rdata;
  reg csr_wen = 0, csr_ecallen = 0;

  ysyx_CSR_Reg csr(
    .clk(clk), .rst(rst), .wen(csr_wen), .ecallen(csr_ecallen),
    .waddr(csr_addr), .wdata(csr_wdata),
    .waddr_add1(csr_addr_add1), .wdata_add1(csr_wdata_add1),
    .rdata_o(csr_rdata), .mepc_o(mepc), .mtvec_o(mtvec)
  );
  assign reg_wdata_o = (
    (opcode == `ysyx_OP_IL_TYPE) ? mem_rdata : 
    (opcode == `ysyx_OP_SYSTEM) ? csr_rdata : reg_wdata);
  assign csr_addr = (
    (imm[3:0] == `ysyx_OP_SYSTEM_FUNC3) && imm[15:4] == `ysyx_OP_SYSTEM_ECALL ? `ysyx_CSR_MCAUSE :
    (imm[3:0] == `ysyx_OP_SYSTEM_FUNC3) && imm[15:4] == `ysyx_OP_SYSTEM_MRET  ? `ysyx_CSR_MSTATUS :
    (imm[15:4]));
  assign csr_addr_add1 = (
    (imm[3:0] == `ysyx_OP_SYSTEM_FUNC3) && imm[15:4] == `ysyx_OP_SYSTEM_ECALL ? `ysyx_CSR_MEPC :
    (0));

  // branch/system unit
  always @(*) begin
    npc_wdata_o = npc;
    csr_wdata = 'h0; csr_wen = 0; csr_ecallen = 0;
    case (opcode)
      `ysyx_OP_SYSTEM: begin
        // $display("sys imm: %h, op1: %h, csr_addr: %h, npc: %h, mtvec: %h", imm[3:0], op1, csr_addr, npc, mtvec);
        case (imm[3:0])
          `ysyx_OP_SYSTEM_FUNC3: begin
            case (imm[15:4])
              `ysyx_OP_SYSTEM_ECALL:  begin 
                csr_wen = 1; csr_wdata = 'hb; csr_wdata_add1 = npc - 4; 
                npc_wdata_o = mtvec; csr_ecallen = 1;
                end
              `ysyx_OP_SYSTEM_EBREAK: begin npc_exu_ebreak(); end
              `ysyx_OP_SYSTEM_MRET:   begin 
                csr_wen = 1; csr_wdata = csr_rdata;
                csr_wdata[`ysyx_CSR_MSTATUS_MIE_IDX] = csr_rdata[`ysyx_CSR_MSTATUS_MPIE_IDX];
                csr_wdata[`ysyx_CSR_MSTATUS_MPIE_IDX] = 1'b1;
                npc_wdata_o = mepc;
                end
              default: begin end
            endcase
          end
          `ysyx_OP_SYSTEM_CSRRW:  begin csr_wen = 1; csr_wdata = op1; end
          `ysyx_OP_SYSTEM_CSRRS:  begin csr_wen = 1; csr_wdata = csr_rdata | op1;   end
          `ysyx_OP_SYSTEM_CSRRC:  begin csr_wen = 1; csr_wdata = csr_rdata & ~op1;  end
          `ysyx_OP_SYSTEM_CSRRWI: begin csr_wen = 1; csr_wdata = op1; end
          `ysyx_OP_SYSTEM_CSRRSI: begin csr_wen = 1; csr_wdata = csr_rdata | op1;   end
          `ysyx_OP_SYSTEM_CSRRCI: begin csr_wen = 1; csr_wdata = csr_rdata & ~op1;  end
          default: begin ; end
        endcase
      end
      `ysyx_OP_JAL, `ysyx_OP_JALR: begin npc_wdata_o = npc_wdata; end
      `ysyx_OP_B_TYPE: begin
        // $display("reg_wdata: %h, npc_wdata: %h, npc: %h", reg_wdata, npc_wdata, npc);
        case (alu_op)
          `ysyx_ALU_OP_SUB:  begin npc_wdata_o = (~|reg_wdata) ? npc_wdata : npc; end
          `ysyx_ALU_OP_XOR:  begin npc_wdata_o = (|reg_wdata) ? npc_wdata : npc; end
          `ysyx_ALU_OP_SLT:  begin npc_wdata_o = (|reg_wdata) ? npc_wdata : npc; end
          `ysyx_ALU_OP_SLTU: begin npc_wdata_o = (|reg_wdata) ? npc_wdata : npc; end
          `ysyx_ALU_OP_SLE:  begin npc_wdata_o = (|reg_wdata) ? npc_wdata : npc; end
          `ysyx_ALU_OP_SLEU: begin npc_wdata_o = (|reg_wdata) ? npc_wdata : npc; end
          default:           begin npc_wdata_o = 0 ; end
        endcase
      end
      default: begin end
    endcase
  end

  // load/store unit
  always @(posedge clk ) begin
    case (opcode)
      `ysyx_OP_S_TYPE: begin
        case (alu_op)
          `ysyx_ALU_OP_SB: begin pmem_write(npc_wdata, op2, 8'h1); end
          `ysyx_ALU_OP_SH: begin pmem_write(npc_wdata, op2, 8'h3); end
          `ysyx_ALU_OP_SW: begin pmem_write(npc_wdata, op2, 8'hf); end
          default:         begin npc_illegal_inst(); end
        endcase
      end
      `ysyx_OP_IL_TYPE: begin
        pmem_read(npc_wdata, mem_rdata_buf[0]);
        case (alu_op)
          `ysyx_ALU_OP_LB, `ysyx_ALU_OP_LBU:  begin 
            mem_rdata = mem_rdata_buf[0] & 'hff;
            if (mem_rdata[7] == 1 && alu_op == `ysyx_ALU_OP_LB) begin
              mem_rdata = mem_rdata | 'hffffff00;
            end
          end
          `ysyx_ALU_OP_LH, `ysyx_ALU_OP_LHU:  begin
            mem_rdata = mem_rdata_buf[0] & 'hffff;
            if (mem_rdata[15] == 1 && alu_op == `ysyx_ALU_OP_LH) begin
              mem_rdata = mem_rdata | 'hffff0000;
            end
           end
          `ysyx_ALU_OP_LW:  begin mem_rdata = mem_rdata_buf[0]; end
          default: begin end
        endcase
      end
      default: begin end
    endcase
  end

  // alu unit for reg_wdata
  ysyx_ALU #(BIT_W) alu(
    .alu_op1(op1), .alu_op2(op2), .alu_op(alu_op),
    .alu_res_o(reg_wdata)
    );
  
  // alu unit for npc_wdata
  ysyx_ALU #(BIT_W) alu_j(
    .alu_op1(op_j), .alu_op2(imm), .alu_op(`ysyx_ALU_OP_ADD),
    .alu_res_o(npc_wdata)
    );

endmodule // ysyx_EXU

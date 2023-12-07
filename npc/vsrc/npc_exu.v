import "DPI-C" function void npc_exu_ebreak ();
import "DPI-C" function void pmem_read (input int raddr, output int rdata);
import "DPI-C" function void pmem_write (
  input int waddr, input int wdata, input byte wmask);

`include "npc_common.v"

module ysyx_EXU (
  input wire clk,
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
  wire [BIT_W-1:0] reg_wdata;
  reg [BIT_W-1:0] mem_rdata;
  reg [31:0] mem_rdata_buf [0:1];

  // branch unit
  always @(*) begin
    npc_wdata_o = npc;
    reg_wdata_o = (opcode != `ysyx_OP_IL_TYPE) ? reg_wdata : mem_rdata;
    case (opcode)
      `ysyx_OP_SYSTEM_EBREAK: begin
        npc_exu_ebreak(); // ebreak
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

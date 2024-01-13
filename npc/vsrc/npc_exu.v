`include "npc_macro.v"
`include "npc_macro_csr.v"

module ysyx_EXU (
  input clk, rst,

  input prev_valid, next_ready,
  output reg valid_o, ready_o,

  // for bus
  output exu_lsu_valid_o,
  output [BIT_W-1:0] exu_lsu_addr_data_o, exu_lsu_mem_wdata_o,
  input [BIT_W-1:0] mem_rdata,
  input rvalid_wready,

  input ren, wen,
  input [BIT_W-1:0] imm,
  input [BIT_W-1:0] op1, op2, op_j,
  input [3:0] alu_op,
  input [6:0] funct7, opcode,
  input [BIT_W-1:0] pc,
  output reg [BIT_W-1:0] reg_wdata_o, npc_wdata_o,
  output reg wben_o
);
  parameter BIT_W = `ysyx_W_WIDTH;

  wire [BIT_W-1:0] addr_data, reg_wdata, mepc, mtvec;
  wire [BIT_W-1:0] mem_wdata = op2;
  // reg [BIT_W-1:0] mem_rdata;
  reg [12-1:0]    csr_addr, csr_addr_add1;
  reg [BIT_W-1:0] csr_wdata, csr_wdata_add1, csr_rdata;
  reg csr_wen = 0, csr_ecallen = 0;

  ysyx_CSR_Reg csr(
    .clk(clk), .rst(rst), .wen(csr_wen), .exu_valid(valid_o), .ecallen(csr_ecallen),
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
  assign addr_data = op_j + imm;

  reg state, alu_valid, lsu_avalid;
  reg valid_once;
  assign valid_o = rvalid_wready & alu_valid;
  assign wben_o = valid_o & valid_once;
  assign ready_o = !valid_o;
  `ysyx_BUS_FSM()
  always @(posedge clk) begin
    if (rst) begin
      alu_valid <= 0; lsu_avalid <= 0;
    end
    else begin
      if (state == `ysyx_IDLE & prev_valid) begin
        alu_valid <= 1;
        if (wen | ren) begin lsu_avalid <= 1; end
      end
      else if (state == `ysyx_WAIT_READY) begin
        if (next_ready == 1) begin lsu_avalid <= 0; alu_valid <= 0; end
      end
      if (valid_o) begin
        valid_once <= 0;
      end else begin 
        valid_once <= 1;
      end
    end
  end

  assign exu_lsu_valid_o = lsu_avalid;
  assign exu_lsu_addr_data_o = addr_data;
  assign exu_lsu_mem_wdata_o = mem_wdata;

  // alu unit for reg_wdata
  ysyx_ALU #(BIT_W) alu(
    .alu_op1(op1), .alu_op2(op2), .alu_op(alu_op),
    .alu_res_o(reg_wdata)
    );
  
  // branch/system unit
  always @(*) begin
    npc_wdata_o = pc + 4;
    csr_wdata = 'h0; csr_wen = 0; csr_ecallen = 0;
    csr_wdata_add1 = 'h0;
    case (opcode)
      `ysyx_OP_SYSTEM: begin
        // $display("sys imm: %h, op1: %h, csr_addr: %h, npc: %h, mtvec: %h",
        //           imm[3:0], op1, csr_addr, npc, mtvec);
        case (imm[3:0])
          `ysyx_OP_SYSTEM_FUNC3: begin
            case (imm[15:4])
              `ysyx_OP_SYSTEM_ECALL:  begin 
                csr_wen = 1; csr_wdata = 'hb; csr_wdata_add1 = pc; 
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
      `ysyx_OP_JAL, `ysyx_OP_JALR: begin npc_wdata_o = addr_data; end
      `ysyx_OP_B_TYPE: begin
        // $display("reg_wdata: %h, npc_wdata: %h, npc: %h", reg_wdata, npc_wdata, npc);
        case (alu_op)
          `ysyx_ALU_OP_SUB:  begin npc_wdata_o = (~|reg_wdata)? addr_data : pc + 4; end
          `ysyx_ALU_OP_XOR:  begin npc_wdata_o = (|reg_wdata) ? addr_data : pc + 4; end
          `ysyx_ALU_OP_SLT:  begin npc_wdata_o = (|reg_wdata) ? addr_data : pc + 4; end
          `ysyx_ALU_OP_SLTU: begin npc_wdata_o = (|reg_wdata) ? addr_data : pc + 4; end
          `ysyx_ALU_OP_SLE:  begin npc_wdata_o = (|reg_wdata) ? addr_data : pc + 4; end
          `ysyx_ALU_OP_SLEU: begin npc_wdata_o = (|reg_wdata) ? addr_data : pc + 4; end
          default:           begin npc_wdata_o = 0 ; end
        endcase
      end
      default: begin end
    endcase
  end

endmodule // ysyx_EXU

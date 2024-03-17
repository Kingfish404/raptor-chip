`include "ysyx_macro.v"
`include "ysyx_macro_csr.v"

module ysyx_EXU (
  input clk, rst,

  input prev_valid, next_ready,
  output reg valid_o, ready_o,

  // for bus
  output lsu_avalid_o,
  output [BIT_W-1:0] lsu_mem_wdata_o,
  input [BIT_W-1:0] lsu_rdata,
  input lsu_exu_rvalid, lsu_exu_wready,

  input ren, wen, rwen,
  input [4:0] rd,
  input [BIT_W-1:0] imm,
  input [BIT_W-1:0] op1, op2, op_j, rwaddr,
  input [3:0] alu_op,
  input [6:0] opcode,
  input [BIT_W-1:0] pc,
  output reg [BIT_W-1:0] reg_wdata_o, npc_wdata_o,
  output reg [4:0] rd_o,
  output [3:0] alu_op_o,
  output reg rwen_o, wben_o, ebreak_o,
  output reg ren_o, wen_o
);
  parameter BIT_W = `ysyx_W_WIDTH;

  wire [BIT_W-1:0] addr_data, reg_wdata, mepc, mtvec;
  wire [BIT_W-1:0] mem_wdata = src2;
  wire [12-1:0] csr_addr, csr_addr_add1;
  wire [BIT_W-1:0] csr_wdata1, csr_rdata;
  wire [BIT_W-1:0] csr_wdata;
  reg [BIT_W-1:0] imm_exu, pc_exu, src1, src2, addr_exu;
  reg [3:0] alu_op_exu;
  reg [6:0] opcode_exu;
  reg csr_wen = 0;
  reg csr_ecallen = 0;
  reg [BIT_W-1:0] mem_rdata;

  ysyx_CSR_Reg csr(
    .clk(clk), .rst(rst), .wen(csr_wen), .exu_valid(valid_o), .ecallen(csr_ecallen),
    .waddr(csr_addr), .wdata(csr_wdata),
    .waddr_add1(csr_addr_add1), .wdata_add1(csr_wdata1),
    .rdata_o(csr_rdata), .mepc_o(mepc), .mtvec_o(mtvec)
  );

  assign reg_wdata_o = (
    (opcode_exu == `ysyx_OP_IL_TYPE) ? mem_rdata : 
    (opcode_exu == `ysyx_OP_SYSTEM) ? csr_rdata : reg_wdata);
  assign csr_addr = (
    (imm_exu[3:0] == `ysyx_OP_SYSTEM_FUNC3) && imm_exu[15:4] == `ysyx_OP_SYSTEM_ECALL ? `ysyx_CSR_MCAUSE :
    (imm_exu[3:0] == `ysyx_OP_SYSTEM_FUNC3) && imm_exu[15:4] == `ysyx_OP_SYSTEM_MRET  ? `ysyx_CSR_MSTATUS :
    (imm_exu[15:4]));
  assign csr_addr_add1 = (
    (imm_exu[3:0] == `ysyx_OP_SYSTEM_FUNC3) && imm_exu[15:4] == `ysyx_OP_SYSTEM_ECALL ? `ysyx_CSR_MEPC :
    (0));
  assign addr_data = addr_exu;
  assign alu_op_o = alu_op_exu;

  reg state, alu_valid, lsu_avalid;
  reg valid_once;
  reg lsu_valid;
  assign valid_o = (wen_o | ren_o) ? lsu_valid : alu_valid;
  // assign valid_o = lsu_exu_wready & lsu_exu_rvalid & alu_valid;
  assign wben_o = valid_o & valid_once;
  // assign ready_o = !valid_o;
  assign ready_o = (state != `ysyx_WAIT_READY);
  `ysyx_BUS_FSM()
  always @(posedge clk) begin
    if (rst) begin
      alu_valid <= 0; lsu_avalid <= 0;
    end
    else begin
      if (state == `ysyx_IDLE) begin
        if (prev_valid) begin
          imm_exu <= imm; pc_exu <= pc;
          src1 <= op1; src2 <= op2;
          alu_op_exu <= alu_op; opcode_exu <= opcode;
          addr_exu <= op_j + imm; 
          rd_o <= rd; rwen_o <= rwen;
          ren_o <= ren; wen_o <= wen;
          alu_valid <= 1;
          if (wen | ren) begin lsu_avalid <= 1; end
        end
      end
      else if (state == `ysyx_WAIT_READY) begin
        if (next_ready == 1) begin lsu_avalid <= 0; alu_valid <= 0; end
      end
      if (lsu_valid) begin valid_once <= 0;
      end else begin  valid_once <= 1; end
      if (wen_o) begin 
        if (lsu_exu_wready) begin
          lsu_valid <= 1;
          lsu_avalid <= 0;
        end
      end
      if (ren_o) begin
        if (lsu_exu_rvalid) begin
          lsu_valid <= 1;
          lsu_avalid <= 0;
          mem_rdata <= lsu_rdata;
        end
      end
    end
  end

  assign lsu_avalid_o = lsu_avalid;
  assign lsu_mem_wdata_o = mem_wdata;

  // alu unit for reg_wdata
  ysyx_ALU #(BIT_W) alu(
    .alu_src1(src1), .alu_src2(src2), .alu_op(alu_op_exu),
    .alu_res_o(reg_wdata)
    );
  
  // branch/system unit
  assign csr_wdata1 = (imm_exu[3:0] == `ysyx_OP_SYSTEM_FUNC3 && imm_exu[15:4] == `ysyx_OP_SYSTEM_ECALL) ? pc_exu : 'h0;
  assign csr_ecallen = ((opcode_exu == `ysyx_OP_SYSTEM) && imm_exu[3:0] == `ysyx_OP_SYSTEM_FUNC3 && imm_exu[15:4] == `ysyx_OP_SYSTEM_ECALL);
  assign csr_wen = (opcode_exu == `ysyx_OP_SYSTEM) && (
    ((imm_exu[3:0] == `ysyx_OP_SYSTEM_FUNC3) && (imm_exu[15:4] == `ysyx_OP_SYSTEM_ECALL)) |
    ((imm_exu[3:0] == `ysyx_OP_SYSTEM_FUNC3) && (imm_exu[15:4] == `ysyx_OP_SYSTEM_MRET)) |
    ((imm_exu[3:0] == `ysyx_OP_SYSTEM_CSRRW)) |
    ((imm_exu[3:0] == `ysyx_OP_SYSTEM_CSRRS)) |
    ((imm_exu[3:0] == `ysyx_OP_SYSTEM_CSRRC)) |
    ((imm_exu[3:0] == `ysyx_OP_SYSTEM_CSRRWI)) |
    ((imm_exu[3:0] == `ysyx_OP_SYSTEM_CSRRSI)) |
    ((imm_exu[3:0] == `ysyx_OP_SYSTEM_CSRRCI)) 
  );
  assign csr_wdata = {BIT_W{(opcode_exu == `ysyx_OP_SYSTEM)}} & (
    ({BIT_W{((imm_exu[3:0] == `ysyx_OP_SYSTEM_FUNC3) && (imm_exu[15:4] == `ysyx_OP_SYSTEM_ECALL))}} & 'hb) |
    ({BIT_W{((imm_exu[3:0] == `ysyx_OP_SYSTEM_FUNC3) && (imm_exu[15:4] == `ysyx_OP_SYSTEM_MRET))}} &
     {{csr_rdata[BIT_W-1:'h8]}, 1'b1, {csr_rdata[6:4]}, csr_rdata['h7], csr_rdata[2:0]}) |
    ({BIT_W{((imm_exu[3:0] == `ysyx_OP_SYSTEM_CSRRW))}} & src1) |
    ({BIT_W{((imm_exu[3:0] == `ysyx_OP_SYSTEM_CSRRS))}} & (csr_rdata | src1)) |
    ({BIT_W{((imm_exu[3:0] == `ysyx_OP_SYSTEM_CSRRC))}} & (csr_rdata & ~src1)) |
    ({BIT_W{((imm_exu[3:0] == `ysyx_OP_SYSTEM_CSRRWI))}} & src1) |
    ({BIT_W{((imm_exu[3:0] == `ysyx_OP_SYSTEM_CSRRSI))}} & (csr_rdata | src1)) |
    ({BIT_W{((imm_exu[3:0] == `ysyx_OP_SYSTEM_CSRRCI))}} & (csr_rdata & ~src1))
  );
  assign ebreak_o = (opcode_exu == `ysyx_OP_SYSTEM) && (imm_exu[3:0] == `ysyx_OP_SYSTEM_FUNC3) && (imm_exu[15:4] == `ysyx_OP_SYSTEM_EBREAK);
  always @(*) begin
    npc_wdata_o = pc_exu + 4;
    case (opcode)
      `ysyx_OP_SYSTEM: begin
        case (imm_exu[3:0])
          `ysyx_OP_SYSTEM_FUNC3: begin
            case (imm_exu[15:4])
              `ysyx_OP_SYSTEM_ECALL:  begin npc_wdata_o = mtvec; end
              `ysyx_OP_SYSTEM_EBREAK: begin npc_exu_ebreak(); end
              `ysyx_OP_SYSTEM_MRET:   begin npc_wdata_o = mepc; end
              default: begin ; end
            endcase
          end
          default: begin ; end
        endcase
      end
      `ysyx_OP_JAL, `ysyx_OP_JALR: begin npc_wdata_o = addr_data; end
      `ysyx_OP_B_TYPE: begin
        // $display("reg_wdata: %h, npc_wdata: %h, npc: %h", reg_wdata, npc_wdata, npc);
        case (alu_op_exu)
          `ysyx_ALU_OP_SUB:  begin npc_wdata_o = (~|reg_wdata)? addr_data : pc_exu + 4; end
          `ysyx_ALU_OP_XOR:  begin npc_wdata_o = (|reg_wdata) ? addr_data : pc_exu + 4; end
          `ysyx_ALU_OP_SLT:  begin npc_wdata_o = (|reg_wdata) ? addr_data : pc_exu + 4; end
          `ysyx_ALU_OP_SLTU: begin npc_wdata_o = (|reg_wdata) ? addr_data : pc_exu + 4; end
          `ysyx_ALU_OP_SLE:  begin npc_wdata_o = (|reg_wdata) ? addr_data : pc_exu + 4; end
          `ysyx_ALU_OP_SLEU: begin npc_wdata_o = (|reg_wdata) ? addr_data : pc_exu + 4; end
          default:           begin ; end
        endcase
      end
      default: begin end
    endcase
  end

endmodule // ysyx_EXU

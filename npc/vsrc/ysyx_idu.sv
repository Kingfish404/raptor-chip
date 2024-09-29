
module ysyx_idu (
    input clk,
    input rst,

    input [31:0] inst,
    input [BIT_W-1:0] rdata1,
    input [BIT_W-1:0] rdata2,
    input [BIT_W-1:0] pc,
    input speculation,

    input exu_valid,
    input [BIT_W-1:0] exu_forward,
    input [3:0] exu_forward_rd,

    output [3:0] rs1_o,
    output [3:0] rs2_o,

    idu_pipe_if idu_if,

    input [16-1:0] rf_table,

    input prev_valid,
    input next_ready,
    output reg valid_o,
    output reg ready_o
);
  parameter bit [7:0] BIT_W = 32;

  reg [31:0] inst_idu, pc_idu;
  reg valid, ready;

  logic en_j_o;
  logic ren_o;
  logic wen_o;
  logic system_o;
  logic system_func3_o;
  logic csr_wen_o;
  logic ebreak_o;
  logic [BIT_W-1:0] op1_o;
  logic [BIT_W-1:0] op2_o;
  logic [BIT_W-1:0] op_j_o;
  logic [31:0] imm_o;
  logic [3:0] rd_o;
  logic [3:0] alu_op_o;
  logic [BIT_W-1:0] pc_o;
  logic [31:0] inst_o;
  logic speculation_o;

  // wire [4:0] rs1 = inst_idu[19:15], rs2 = inst_idu[24:20], rd = inst_idu[11:7];
  wire [3:0] rs1 = inst_idu[18:15], rs2 = inst_idu[23:20], rd = inst_idu[10:7];
  wire wen, ren;
  wire idu_hazard = valid & (
    opcode != `YSYX_OP_LUI & opcode != `YSYX_OP_AUIPC & opcode != `YSYX_OP_JAL &
    ((rf_table[rs1[4-1:0]] == 1) & !(exu_valid & rs1[4-1:0] == exu_forward_rd)) |
    ((rf_table[rs2[4-1:0]] == 1) & !(exu_valid & rs2[4-1:0] == exu_forward_rd)) |
    (0)
    );
  wire [BIT_W-1:0] reg_rdata1 = exu_valid & rs1[4-1:0] == exu_forward_rd ? exu_forward : rdata1;
  wire [BIT_W-1:0] reg_rdata2 = exu_valid & rs2[4-1:0] == exu_forward_rd ? exu_forward : rdata2;
  wire [6:0] opcode = inst_idu[6:0];
  assign valid_o = valid & !idu_hazard;
  assign ready_o = ready & !idu_hazard & next_ready;
  assign inst_o = inst_idu;
  assign pc_o = pc_idu;
  assign wen_o = wen;
  assign rs1_o = rs1;
  assign rs2_o = rs2;

  reg state;
  `YSYX_BUS_FSM()
  always @(posedge clk) begin
    if (rst) begin
      valid <= 0;
      ready <= 1;
    end else begin
      if (prev_valid & ready & !idu_hazard & next_ready) begin
        inst_idu <= inst;
        pc_idu <= pc;
        speculation_o <= speculation;
      end
      if (state == `YSYX_IDLE) begin
        if (prev_valid & ready & !idu_hazard & next_ready) begin
          valid <= 1;
          if (idu_hazard) begin
            ready <= 0;
          end
        end
      end else if (state == `YSYX_WAIT_READY) begin
        if (next_ready == 1) begin
          ready <= 1;
          if (prev_valid & ready_o & next_ready) begin
          end else begin
            valid <= 0;
            inst_idu <= 0;
          end
        end
      end
    end
  end

  assign idu_if.wen = wen_o;
  assign idu_if.ren = ren_o;
  assign idu_if.jen = en_j_o;

  assign idu_if.system = system_o;
  assign idu_if.system_func3_z = system_func3_o;
  assign idu_if.csr_wen = csr_wen_o;
  assign idu_if.ebreak = ebreak_o;

  assign idu_if.op1 = op1_o;
  assign idu_if.op2 = op2_o;
  assign idu_if.opj = op_j_o;
  assign idu_if.alu_op = alu_op_o;
  assign idu_if.rd = rd_o;
  assign idu_if.imm = imm_o;

  assign idu_if.pc = pc_o;
  assign idu_if.inst = inst_o;
  assign idu_if.speculation = speculation_o;

  ysyx_idu_decoder idu_de (
      .clock(clk),
      .reset(rst),

      .in_inst(inst_idu),
      .in_pc  (pc_idu),
      .in_rs1v(reg_rdata1),
      .in_rs2v(reg_rdata2),

      .out_rd(rd_o),
      .out_imm(imm_o),
      .out_op1(op1_o),
      .out_op2(op2_o),
      .out_wen(wen_o),
      .out_ren(ren_o),
      .out_alu_op(alu_op_o),
      .out_en_j(en_j_o),
      .out_opj(op_j_o),

      .out_sys_ebreak(ebreak_o),
      .out_sys_system_func3_zero(system_func3_o),
      .out_sys_csr_wen(csr_wen_o),
      .out_sys_system(system_o)
  );
endmodule  // ysyx_IDU


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
  reg speculation_idu;
  reg valid, ready;

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
  assign rs1_o   = rs1;
  assign rs2_o   = rs2;

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
        speculation_idu <= speculation;
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

  assign idu_if.pc = pc_idu;
  assign idu_if.inst = inst_idu;
  assign idu_if.speculation = speculation_idu;

  ysyx_idu_decoder idu_de (
      .clock(clk),
      .reset(rst),

      .in_pc  (pc_idu),
      .in_inst(inst_idu),

      .in_rs1v(reg_rdata1),
      .in_rs2v(reg_rdata2),

      .out_op1(idu_if.op1),
      .out_op2(idu_if.op2),
      .out_opj(idu_if.opj),
      .out_alu_op(idu_if.alu_op),

      .out_rd (idu_if.rd),
      .out_imm(idu_if.imm),

      .out_wen(idu_if.wen),
      .out_ren(idu_if.ren),
      .out_jen(idu_if.jen),
      .out_ben(idu_if.ben),

      .out_sys_system(idu_if.system),
      .out_sys_func3_zero(idu_if.func3_z),
      .out_sys_csr_wen(idu_if.csr_wen),
      .out_sys_ebreak(idu_if.ebreak),
      .out_sys_ecall(idu_if.ecall),
      .out_sys_mret(idu_if.mret)
  );
endmodule  // ysyx_IDU

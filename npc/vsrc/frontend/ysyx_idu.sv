`include "ysyx.svh"
`include "ysyx_if.svh"

module ysyx_idu (
    input clock,
    input reset,

    input [31:0] inst,
    input [XLEN-1:0] rdata1,
    input [XLEN-1:0] rdata2,
    input [XLEN-1:0] pc,

    input exu_valid,
    input [XLEN-1:0] exu_forward,
    input [`YSYX_REG_LEN-1:0] exu_forward_rd,

    output [`YSYX_REG_LEN-1:0] out_rs1,
    output [`YSYX_REG_LEN-1:0] out_rs2,

    idu_pipe_if.out idu_if,

    input [`YSYX_REG_NUM-1:0] rf_table,

    input prev_valid,
    input next_ready,
    output reg out_valid,
    output reg out_ready
);
  parameter bit [7:0] XLEN = `YSYX_XLEN;

  reg [31:0] inst_idu, pc_idu;
  reg valid, ready;

  wire [4:0] rd;
  wire [`YSYX_REG_LEN-1:0]
    rs1 = inst_idu[15+`YSYX_REG_LEN-1:15],
    rs2 = inst_idu[20+`YSYX_REG_LEN-1:20];

  wire wen, ren, indie;
  wire idu_hazard = valid && (indie == 0) && (
    ((rf_table[rs1[`YSYX_REG_LEN-1:0]] == 1) &&
       !(exu_valid && rs1[`YSYX_REG_LEN-1:0] == exu_forward_rd)) ||
    ((rf_table[rs2[`YSYX_REG_LEN-1:0]] == 1) &&
       !(exu_valid && rs2[`YSYX_REG_LEN-1:0] == exu_forward_rd)) ||
    (0));
  wire [XLEN-1:0] reg_rdata1 = (exu_valid && rs1[`YSYX_REG_LEN-1:0] == exu_forward_rd)
    ? exu_forward : rdata1;
  wire [XLEN-1:0] reg_rdata2 = (exu_valid && rs2[`YSYX_REG_LEN-1:0] == exu_forward_rd)
    ? exu_forward : rdata2;
  assign out_valid = valid && !idu_hazard;
  assign out_ready = ready && !idu_hazard && next_ready;
  assign out_rs1   = rs1;
  assign out_rs2   = rs2;

  always @(posedge clock) begin
    if (reset) begin
      valid <= 0;
      ready <= 1;
    end else begin
      if (prev_valid && ready && !idu_hazard && next_ready) begin
        inst_idu <= inst;
        pc_idu   <= pc;
      end
      if (prev_valid && ready && !idu_hazard && next_ready) begin
        valid <= 1;
        if (idu_hazard) begin
          ready <= 0;
        end
      end
      if (next_ready == 1) begin
        ready <= 1;
        if (prev_valid && out_ready) begin
        end else begin
          valid <= 0;
          inst_idu <= 0;
        end
      end
    end
  end

  assign idu_if.pc = pc_idu;
  assign idu_if.inst = inst_idu;
  assign idu_if.func3 = inst_idu[14:12];
  assign idu_if.rd[`YSYX_REG_LEN-1:0] = rd[`YSYX_REG_LEN-1:0];

  ysyx_idu_decoder idu_de (
      .clock(clock),

      .in_pc  (pc_idu),
      .in_inst(inst_idu),

      .in_rs1v(reg_rdata1),
      .in_rs2v(reg_rdata2),

      .out_op1(idu_if.op1),
      .out_op2(idu_if.op2),
      .out_opj(idu_if.opj),
      .out_alu_op(idu_if.alu_op),

      .out_rd (rd),
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
      .out_sys_mret(idu_if.mret),

      .out_indie(indie),

      .reset(reset)
  );
endmodule  // ysyx_idu

`include "ysyx.svh"
`include "ysyx_if.svh"

module ysyx_idu #(
    parameter bit [7:0] XLEN = `YSYX_XLEN
) (
    input clock,
    input reset,

    input [31:0] inst,
    input [XLEN-1:0] pc,
    input [XLEN-1:0] pnpc,
    idu_pipe_if.out idu_if,

    input prev_valid,
    input next_ready,
    output logic out_valid,
    output logic out_ready
);
  logic [31:0] inst_idu, pc_idu, pnpc_idu;
  logic valid, ready;

  logic [4:0] rd;

  assign out_valid = valid;
  assign out_ready = ready && next_ready;

  always @(posedge clock) begin
    if (reset) begin
      valid <= 0;
      ready <= 1;
    end else begin
      if (prev_valid && ready && next_ready) begin
        inst_idu <= inst;
        pc_idu   <= pc;
        pnpc_idu <= pnpc;
      end
      if (prev_valid && ready && next_ready) begin
        valid <= 1;
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
  assign idu_if.pnpc = pnpc_idu;
  assign idu_if.rd[`YSYX_REG_LEN-1:0] = rd[`YSYX_REG_LEN-1:0];

  ysyx_idu_decoder idu_de (
      .clock(clock),

      .out_alu_op(idu_if.alu_op),
      .out_jen(idu_if.jen),
      .out_ben(idu_if.ben),
      .out_wen(idu_if.wen),
      .out_ren(idu_if.ren),

      .out_sys_system(idu_if.system),
      .out_sys_ebreak(idu_if.ebreak),
      .out_sys_fence_i(idu_if.fence_i),
      .out_sys_ecall(idu_if.ecall),
      .out_sys_mret(idu_if.mret),
      .out_sys_csr_csw(idu_if.csr_csw),

      .out_rd (rd),
      .out_imm(idu_if.imm),
      .out_op1(idu_if.op1),
      .out_op2(idu_if.op2),
      .out_rs1(idu_if.rs1),
      .out_rs2(idu_if.rs2),

      .in_inst(inst_idu),

      .in_pc(pc_idu),

      .reset(reset)
  );
endmodule

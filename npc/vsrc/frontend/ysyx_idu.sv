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

  logic [ 4:0] alu;
  logic [ 4:0] rd;
  logic [11:0] csr;
  logic [ 2:0] csr_csw;
  logic illegal_csr, illegal_inst;

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

  assign idu_if.alu = alu;
  assign idu_if.pc = pc_idu;
  assign idu_if.inst = inst_idu;
  assign idu_if.pnpc = pnpc_idu;
  assign idu_if.rd[`YSYX_REG_LEN-1:0] = illegal_csr || illegal_inst ? 0 : rd[`YSYX_REG_LEN-1:0];

  assign idu_if.csr_csw = csr_csw;

  assign idu_if.trap = illegal_csr || illegal_inst;
  assign idu_if.tval = illegal_csr || illegal_inst ? inst_idu : 0;
  assign idu_if.cause = illegal_csr || illegal_inst ? 'h2 : 0;

  assign illegal_inst = alu == `YSYX_ALU_ILL_;
  assign illegal_csr = (csr_csw != 3'b000) && !(
      csr == `YSYX_CSR_SSTATUS ||
      csr == `YSYX_CSR_SIE____ ||
      csr == `YSYX_CSR_STVEC__ ||

      csr == `YSYX_CSR_SCOUNTE ||

      csr == `YSYX_CSR_SSCRATC ||
      csr == `YSYX_CSR_SEPC___ ||
      csr == `YSYX_CSR_SCAUSE_ ||
      csr == `YSYX_CSR_STVAL__ ||
      csr == `YSYX_CSR_SIP____ ||
      csr == `YSYX_CSR_SATP___ ||

      csr == `YSYX_CSR_MSTATUS ||
      csr == `YSYX_CSR_MISA___ ||
      csr == `YSYX_CSR_MEDELEG ||
      csr == `YSYX_CSR_MIDELEG ||
      csr == `YSYX_CSR_MIE____ ||
      csr == `YSYX_CSR_MTVEC__ ||

      csr == `YSYX_CSR_MSTATUSH||
      csr == `YSYX_CSR_MSCRATCH||
      csr == `YSYX_CSR_MEPC___ ||
      csr == `YSYX_CSR_MCAUSE_ ||
      csr == `YSYX_CSR_MTVAL__ ||
      csr == `YSYX_CSR_MIP____ ||

      csr == `YSYX_CSR_MCYCLE_ ||
      csr == `YSYX_CSR_TIME___ ||
      csr == `YSYX_CSR_TIMEH__ ||

      csr == `YSYX_CSR_MVENDORID ||
      csr == `YSYX_CSR_MARCHID__ ||
      csr == `YSYX_CSR_IMPID____ ||
      csr == `YSYX_CSR_MHARTID__ ||
      0
  );

  ysyx_idu_decoder idu_de (
      .clock(clock),

      .out_alu(alu),
      .out_jen(idu_if.jen),
      .out_ben(idu_if.ben),
      .out_wen(idu_if.wen),
      .out_ren(idu_if.ren),

      .out_atom(idu_if.atom),

      .out_sys_system(idu_if.system),
      .out_sys_ebreak(idu_if.ebreak),
      .out_sys_ecall(idu_if.ecall),
      .out_sys_mret(idu_if.mret),
      .out_sys_csr_csw(csr_csw),

      .out_fence_i(idu_if.fence_i),
      .out_fence_time(idu_if.fence_time),

      .out_rd (rd),
      .out_imm(idu_if.imm),
      .out_op1(idu_if.op1),
      .out_op2(idu_if.op2),
      .out_rs1(idu_if.rs1),
      .out_rs2(idu_if.rs2),
      .out_csr(csr),

      .in_inst(inst_idu),

      .in_pc(pc_idu),

      .reset(reset)
  );
endmodule

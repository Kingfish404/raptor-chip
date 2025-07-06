`include "ysyx.svh"
`include "ysyx_if.svh"

module ysyx_idu #(
    parameter bit [7:0] XLEN = `YSYX_XLEN
) (
    input clock,
    input reset,

    input flush_pipe,

    ifu_idu_if.slave ifu_idu,
    idu_pipe_if.out  idu_rou,

    input prev_valid,
    input next_ready,
    output logic out_valid,
    output logic out_ready
);
  typedef enum logic [1:0] {
    IDLE  = 'b00,
    VALID = 'b01
  } state_idu_t;

  state_idu_t state_idu;

  logic [31:0] inst_idu, pc_idu, pnpc_idu;

  logic [ 4:0] alu;
  logic [ 4:0] rd;
  logic [11:0] csr;
  logic [ 2:0] csr_csw;
  logic illegal_csr, illegal_inst;

  assign out_valid = state_idu == VALID;
  assign out_ready = state_idu == IDLE || (next_ready && state_idu == VALID);

  always @(posedge clock) begin
    if (reset) begin
      state_idu <= IDLE;
    end else begin
      unique case (state_idu)
        IDLE: begin
          if (prev_valid) begin
            state_idu <= VALID;
          end else begin
            state_idu <= IDLE;
          end
        end
        VALID: begin
          if (flush_pipe) begin
            state_idu <= IDLE;
          end else if (next_ready) begin
            if (prev_valid) begin
            end else begin
              state_idu <= IDLE;
            end
          end
        end
        default: begin
        end
      endcase
      if (state_idu == IDLE || next_ready) begin
        if (ifu_idu.valid) begin
          inst_idu <= ifu_idu.inst;
          pc_idu   <= ifu_idu.pc;
          pnpc_idu <= ifu_idu.pnpc;
        end
      end
    end
  end

  assign idu_rou.alu = alu;
  assign idu_rou.pc = pc_idu;
  assign idu_rou.inst = inst_idu;
  assign idu_rou.pnpc = pnpc_idu;
  assign idu_rou.rd[`YSYX_REG_LEN-1:0] = illegal_csr || illegal_inst ? 0 : rd[`YSYX_REG_LEN-1:0];

  assign idu_rou.csr_csw = csr_csw;

  assign idu_rou.trap = illegal_csr || illegal_inst;
  assign idu_rou.tval = illegal_csr || illegal_inst ? inst_idu : 0;
  assign idu_rou.cause = illegal_csr || illegal_inst ? 'h2 : 0;

  assign illegal_inst = alu == `YSYX_ALU_ILL_;
  assign illegal_csr = (csr_csw != 3'b000) && !((0)
      || (csr == `YSYX_CSR_SSTATUS)
      || (csr == `YSYX_CSR_SIE____)
      || (csr == `YSYX_CSR_STVEC__)
      || (csr == `YSYX_CSR_SCOUNTE)

      || (csr == `YSYX_CSR_SSCRATC)
      || (csr == `YSYX_CSR_SEPC___)
      || (csr == `YSYX_CSR_SCAUSE_)
      || (csr == `YSYX_CSR_STVAL__)
      || (csr == `YSYX_CSR_SIP____)
      || (csr == `YSYX_CSR_SATP___)

      || (csr == `YSYX_CSR_MSTATUS)
      || (csr == `YSYX_CSR_MISA___)
      || (csr == `YSYX_CSR_MEDELEG)
      || (csr == `YSYX_CSR_MIDELEG)
      || (csr == `YSYX_CSR_MIE____)
      || (csr == `YSYX_CSR_MTVEC__)

      || (csr == `YSYX_CSR_MSTATUSH)
      || (csr == `YSYX_CSR_MSCRATCH)
      || (csr == `YSYX_CSR_MEPC___)
      || (csr == `YSYX_CSR_MCAUSE_)
      || (csr == `YSYX_CSR_MTVAL__)
      || (csr == `YSYX_CSR_MIP____)

      || (csr == `YSYX_CSR_MCYCLE_)
      || (csr == `YSYX_CSR_TIME___)
      || (csr == `YSYX_CSR_TIMEH__)

      || (csr == `YSYX_CSR_MVENDORID)
      || (csr == `YSYX_CSR_MARCHID__)
      || (csr == `YSYX_CSR_IMPID____)
      || (csr == `YSYX_CSR_MHARTID__)
  );

  ysyx_idu_decoder idu_de (
      .clock(clock),

      .out_alu(alu),
      .out_jen(idu_rou.jen),
      .out_ben(idu_rou.ben),
      .out_sen(idu_rou.wen),
      .out_len(idu_rou.ren),

      .out_atom(idu_rou.atom),

      .out_sys_system(idu_rou.system),
      .out_sys_ebreak(idu_rou.ebreak),
      .out_sys_ecall(idu_rou.ecall),
      .out_sys_mret(idu_rou.mret),
      .out_sys_csr_csw(csr_csw),

      .out_fence_i(idu_rou.fence_i),
      .out_fence_time(idu_rou.fence_time),

      .out_rd (rd),
      .out_imm(idu_rou.imm),
      .out_op1(idu_rou.op1),
      .out_op2(idu_rou.op2),
      .out_rs1(idu_rou.rs1),
      .out_rs2(idu_rou.rs2),
      .out_csr(csr),

      .in_inst(inst_idu),

      .in_pc(pc_idu),

      .reset(reset)
  );
endmodule

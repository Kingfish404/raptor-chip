`include "ysyx.svh"
`include "ysyx_if.svh"

module ysyx_idu #(
    parameter unsigned RLEN = `YSYX_REG_LEN,
    parameter bit [7:0] XLEN = `YSYX_XLEN
) (
    input clock,

    cmu_bcast_if.in cmu_bcast,

    ifu_idu_if.slave  ifu_idu,
    idu_rnu_if.master idu_rnu,

    input reset
);
  typedef enum {
    IDLE  = 'b00,
    VALID = 'b01
  } state_idu_t;

  state_idu_t state_idu;

  logic [31:0] inst, inst_de;
  logic [31:0] inst_idu, pc_idu, pnpc_idu;
  logic ifu_trap;
  logic [XLEN-1:0] ifu_cause;

  logic [4:0] alu;
  logic [11:0] csr;
  logic [2:0] csr_csw;
  logic illegal_csr, illegal_inst;
  logic is_c;
  logic valid, ready;
  logic [5-1:0] rd, rs1, rs2;

  assign valid = state_idu == VALID;
  assign ready = state_idu == IDLE || idu_rnu.ready;
  assign idu_rnu.valid = valid;
  assign ifu_idu.ready = ready;

  always @(posedge clock) begin
    if (reset) begin
      state_idu <= IDLE;
    end else begin
      unique case (state_idu)
        IDLE: begin
          if (cmu_bcast.flush_pipe) begin
          end else if (ifu_idu.valid) begin
            state_idu <= VALID;
          end else begin
            state_idu <= IDLE;
          end
        end
        VALID: begin
          if (cmu_bcast.flush_pipe) begin
            state_idu <= IDLE;
          end else if (idu_rnu.ready) begin
            if (ifu_idu.valid) begin
            end else begin
              state_idu <= IDLE;
            end
          end
        end
        default: begin
        end
      endcase
      if (state_idu == IDLE || idu_rnu.ready) begin
        if (ifu_idu.valid) begin

          inst <= ifu_idu.inst;
          pc_idu <= ifu_idu.pc;
          pnpc_idu <= ifu_idu.pnpc;

          ifu_trap <= ifu_idu.trap;
          ifu_cause <= ifu_idu.cause;
        end
      end
    end
  end

  assign is_c = !(inst[1:0] == 2'b11);
  assign inst_idu = is_c ? inst_de : inst;
  assign idu_rnu.uop.c = is_c;
  assign idu_rnu.uop.alu = alu;
  assign idu_rnu.uop.rd[RLEN-1:0] = (illegal_csr || illegal_inst) ? 0 : rd[RLEN-1:0];

  assign idu_rnu.uop.csr_csw = csr_csw;

  assign idu_rnu.uop.trap = ifu_trap || (illegal_csr || illegal_inst);
  assign idu_rnu.uop.tval = ifu_trap ? pc_idu : (illegal_csr || illegal_inst) ? inst_idu : 0;
  assign idu_rnu.uop.cause = ifu_trap ? ifu_cause : (illegal_csr || illegal_inst) ? 'h2 : 0;

  assign idu_rnu.uop.pnpc = pnpc_idu;
  assign idu_rnu.uop.inst = inst_idu;
  assign idu_rnu.uop.pc = pc_idu;

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
      || (csr == `YSYX_CSR_MCYCLEH)
      || (csr == `YSYX_CSR_CYCLE__)
      || (csr == `YSYX_CSR_TIME___)
      || (csr == `YSYX_CSR_TIMEH__)

      || (csr == `YSYX_CSR_MVENDORID)
      || (csr == `YSYX_CSR_MARCHID__)
      || (csr == `YSYX_CSR_IMPID____)
      || (csr == `YSYX_CSR_MHARTID__)
  );

  ysyx_idu_decoder_c idu_de_c (
      .clock(clock),

      .io_cinst(inst[15:0]),
      .io_inst (inst_de),

      .reset(reset)
  );

  assign idu_rnu.rs1[RLEN-1:0] = rs1[RLEN-1:0];
  assign idu_rnu.rs2[RLEN-1:0] = rs2[RLEN-1:0];

  ysyx_idu_decoder idu_de (
      .clock(clock),

      .in_pc  (pc_idu),
      .in_inst(inst_idu),

      .out_alu (alu),
      .out_ben (idu_rnu.uop.ben),
      .out_jen (idu_rnu.uop.jen),
      .out_jren(idu_rnu.uop.jren),
      .out_wen (idu_rnu.uop.wen),
      .out_ren (idu_rnu.uop.ren),

      .out_atom(idu_rnu.uop.atom),

      .out_sys_system(idu_rnu.uop.system),
      .out_sys_ebreak(idu_rnu.uop.ebreak),
      .out_sys_ecall(idu_rnu.uop.ecall),
      .out_sys_mret(idu_rnu.uop.mret),
      .out_sys_sret(idu_rnu.uop.sret),
      .out_sys_csr_csw(csr_csw),

      .out_fence_i(idu_rnu.uop.f_i),
      .out_fence_time(idu_rnu.uop.f_time),

      .out_imm(idu_rnu.uop.imm),
      .out_rd (rd),
      .out_csr(csr),

      .out_op1(idu_rnu.op1),
      .out_op2(idu_rnu.op2),
      .out_rs1(rs1),
      .out_rs2(rs2),

      .reset(reset)
  );
endmodule

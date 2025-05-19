`include "ysyx.svh"
`include "ysyx_if.svh"

module ysyx_iqu #(
    parameter unsigned QUEUE_SIZE = `YSYX_IQU_SIZE,
    parameter unsigned ROB_SIZE = `YSYX_ROB_SIZE,
    parameter unsigned RS_SIZE = `YSYX_RS_SIZE,
    parameter bit [7:0] REG_NUM = `YSYX_REG_NUM,
    parameter bit [7:0] XLEN = `YSYX_XLEN
) (
    input clock,
    input reset,

    // <= idu
    idu_pipe_if.in  idu_if,
    // => exu
    idu_pipe_if.out iqu_exu_if,

    // <= exu
    exu_pipe_if.in exu_wb_if,

    // <=> wbu & reg
    exu_pipe_if.out iqu_wbu_if,

    // <=> reg
    output [4:0] out_rs1,
    output [4:0] out_rs2,
    input [XLEN-1:0] rdata1,
    input [XLEN-1:0] rdata2,

    // => exu (commit)
    exu_pipe_if.out iqu_cm_if,

    // pipeline
    output logic out_flush_pipeline,
    output logic out_fence_time,

    input prev_valid,
    input next_ready,
    output logic out_valid,
    output logic out_ready
);
  typedef enum logic [1:0] {
    CM = 2'b00,
    WB = 2'b01,
    EX = 2'b10
  } rob_state_t;

  logic [4:0] rs1, rs2;

  // === micro-op queue (UOQ) ===
  logic [$clog2(QUEUE_SIZE)-1:0] uoq_tail;
  logic [$clog2(QUEUE_SIZE)-1:0] uoq_head;
  logic [QUEUE_SIZE-1:0] uoq_valid;

  logic [4:0] uoq_alu_op[QUEUE_SIZE];
  logic uoq_jen[QUEUE_SIZE];
  logic uoq_ben[QUEUE_SIZE];
  logic uoq_wen[QUEUE_SIZE];
  logic uoq_ren[QUEUE_SIZE];

  logic uoq_system[QUEUE_SIZE];
  logic uoq_ecall[QUEUE_SIZE];
  logic uoq_ebreak[QUEUE_SIZE];
  logic uoq_mret[QUEUE_SIZE];
  logic [2:0] uoq_csr_csw[QUEUE_SIZE];

  logic uoq_f_i[QUEUE_SIZE];
  logic uoq_f_time[QUEUE_SIZE];

  logic [4:0] uoq_rd[QUEUE_SIZE];
  logic [31:0] uoq_imm[QUEUE_SIZE];
  logic [31:0] uoq_op1[QUEUE_SIZE];
  logic [31:0] uoq_op2[QUEUE_SIZE];
  logic [4:0] uoq_rs1[QUEUE_SIZE];
  logic [4:0] uoq_rs2[QUEUE_SIZE];

  logic [XLEN-1:0] uoq_pnpc[QUEUE_SIZE];
  logic [31:0] uoq_inst[QUEUE_SIZE];
  logic [XLEN-1:0] uoq_pc[QUEUE_SIZE];
  // === micro-op queue (UOQ) ===

  logic dispatch_ready;

  // === re-order buffer (ROB) ===
  logic [$clog2(ROB_SIZE)-1:0] rob_head;
  logic [$clog2(ROB_SIZE)-1:0] rob_tail;

  logic [ROB_SIZE-1:0] rob_busy;
  logic [4:0] rob_rd[ROB_SIZE];
  logic [31:0] rob_inst[ROB_SIZE];
  rob_state_t rob_state[ROB_SIZE];
  logic [XLEN-1:0] rob_pc[ROB_SIZE];
  logic [XLEN-1:0] rob_pnpc[ROB_SIZE];

  logic [XLEN-1:0] rob_value[ROB_SIZE];
  logic [XLEN-1:0] rob_npc[ROB_SIZE];
  logic rob_sys[ROB_SIZE];
  logic rob_br_retire[ROB_SIZE];

  logic rob_csr_wen[ROB_SIZE];
  logic [XLEN-1:0] rob_csr_wdata[ROB_SIZE];
  logic [11:0] rob_csr_addr[ROB_SIZE];

  logic rob_ecall[ROB_SIZE];
  logic rob_ebreak[ROB_SIZE];
  logic rob_mret[ROB_SIZE];

  logic rob_f_i[ROB_SIZE];
  logic rob_f_time[ROB_SIZE];

  logic [$clog2(RS_SIZE)-1:0] rob_rs_idx[ROB_SIZE];
  logic rob_store[ROB_SIZE];
  // === re-order buffer (ROB) ===

  // === Register File (RF) status ===
  logic [$clog2(ROB_SIZE)-1:0] rf_reorder[REG_NUM];
  logic [REG_NUM-1:0] rf_busy;
  // === Register File (RF) status ===

  logic head_is_br;
  logic head_br_p_fail;
  logic head_valid;
  logic flush_pipeline;
  logic fence_time;
  assign out_flush_pipeline = flush_pipeline;
  assign out_fence_time = fence_time;

  assign dispatch_ready = (next_ready && uoq_valid[uoq_tail] && rob_busy[rob_tail] == 0);

  assign out_valid = uoq_valid[uoq_tail] && (rob_busy[rob_tail] == 0);
  assign out_ready = uoq_valid[uoq_head] == 0;

  always @(posedge clock) begin
    if (reset || flush_pipeline) begin
      uoq_head  <= 0;
      uoq_tail  <= 0;
      uoq_valid <= 0;
    end else begin
      if (prev_valid && uoq_valid[uoq_head] == 0) begin
        // Issue to uoq
        uoq_head              <= uoq_head + 1;

        uoq_alu_op[uoq_head]  <= idu_if.alu_op;
        uoq_jen[uoq_head]     <= idu_if.jen;
        uoq_ben[uoq_head]     <= idu_if.ben;
        uoq_wen[uoq_head]     <= idu_if.wen;
        uoq_ren[uoq_head]     <= idu_if.ren;

        uoq_system[uoq_head]  <= idu_if.system;
        uoq_ecall[uoq_head]   <= idu_if.ecall;
        uoq_ebreak[uoq_head]  <= idu_if.ebreak;
        uoq_mret[uoq_head]    <= idu_if.mret;
        uoq_csr_csw[uoq_head] <= idu_if.csr_csw;

        uoq_f_i[uoq_head]     <= idu_if.fence_i;
        uoq_f_time[uoq_head]  <= idu_if.fence_time;

        uoq_rd[uoq_head]      <= idu_if.rd;
        uoq_imm[uoq_head]     <= idu_if.imm;
        uoq_op1[uoq_head]     <= idu_if.op1;
        uoq_op2[uoq_head]     <= idu_if.op2;
        uoq_rs1[uoq_head]     <= idu_if.rs1;
        uoq_rs2[uoq_head]     <= idu_if.rs2;

        uoq_pnpc[uoq_head]    <= idu_if.pnpc;
        uoq_inst[uoq_head]    <= idu_if.inst;
        uoq_pc[uoq_head]      <= idu_if.pc;

        uoq_valid[uoq_head]   <= 1;
      end
      if (dispatch_ready) begin
        // Dispatch to exu and rob
        uoq_tail <= uoq_tail + 1;
        uoq_valid[uoq_tail] <= 0;
        uoq_inst[uoq_tail] <= 0;
      end
    end
  end

  assign rs1 = uoq_rs1[uoq_tail];
  assign rs2 = uoq_rs2[uoq_tail];
  assign out_rs1 = rs1;
  assign out_rs2 = rs2;
  logic rs1_hit_rob;
  logic rs2_hit_rob;
  assign rs1_hit_rob = (rf_busy[rs1[`YSYX_REG_LEN-1:0]] && (rob_state[rf_reorder[rs1[`YSYX_REG_LEN-1:0]]] == WB));
  assign rs2_hit_rob = (rf_busy[rs2[`YSYX_REG_LEN-1:0]] && (rob_state[rf_reorder[rs2[`YSYX_REG_LEN-1:0]]] == WB));
  always_comb begin
    // Dispatch connect
    iqu_exu_if.alu_op = uoq_alu_op[uoq_tail];
    iqu_exu_if.jen = uoq_jen[uoq_tail];
    iqu_exu_if.ben = uoq_ben[uoq_tail];
    iqu_exu_if.wen = uoq_wen[uoq_tail];
    iqu_exu_if.ren = uoq_ren[uoq_tail];

    iqu_exu_if.system = uoq_system[uoq_tail];
    iqu_exu_if.ecall = uoq_ecall[uoq_tail];
    iqu_exu_if.ebreak = uoq_ebreak[uoq_tail];
    iqu_exu_if.mret = uoq_mret[uoq_tail];
    iqu_exu_if.csr_csw = uoq_csr_csw[uoq_tail];

    iqu_exu_if.rd = uoq_rd[uoq_tail];
    iqu_exu_if.imm = uoq_imm[uoq_tail];
    iqu_exu_if.op1 = (rs1 != 0 ?
      (rs1_hit_rob ? rob_value[rf_reorder[rs1[`YSYX_REG_LEN-1:0]]] : rdata1)
      : uoq_op1[uoq_tail]);
    iqu_exu_if.op2 = (rs2 != 0 ?
      (rs2_hit_rob ? rob_value[rf_reorder[rs2[`YSYX_REG_LEN-1:0]]] : rdata2)
      : uoq_op2[uoq_tail]);
    iqu_exu_if.rs1 = (rs1 == 0 || rf_busy[rs1[`YSYX_REG_LEN-1:0]] == 0) ? 0 : rs1;
    iqu_exu_if.rs2 = (rs2 == 0 || rf_busy[rs2[`YSYX_REG_LEN-1:0]] == 0) ? 0 : rs2;

    iqu_exu_if.qj = (rs1 == 0 || rf_busy[rs1[`YSYX_REG_LEN-1:0]] == 0) ? 0 :
      (rs1_hit_rob ? 0 : (rf_reorder[rs1[`YSYX_REG_LEN-1:0]] + 'h1));
    iqu_exu_if.qk = (rs2 == 0 || rf_busy[rs2[`YSYX_REG_LEN-1:0]] == 0) ? 0 :
      (rs2_hit_rob ? 0 : (rf_reorder[rs2[`YSYX_REG_LEN-1:0]] + 'h1));
    iqu_exu_if.dest = {{1'h0}, {rob_tail}} + 'h1;

    iqu_exu_if.inst = uoq_inst[uoq_tail];
    iqu_exu_if.pc = uoq_pc[uoq_tail];
  end

  logic [$clog2(`YSYX_ROB_SIZE)-1:0] wb_dest;
  assign wb_dest = exu_wb_if.dest[$clog2(`YSYX_ROB_SIZE)-1:0] - 1;
  always @(posedge clock) begin
    if (reset || flush_pipeline || fence_time) begin
      rob_head <= 0;
      rob_tail <= 0;
      rob_busy <= 0;
      for (int i = 0; i < ROB_SIZE; i++) begin
        rob_state[i] <= CM;
        rob_inst[i]  <= 0;
      end
      rf_busy <= 0;
      flush_pipeline <= 0;
      fence_time <= 0;
    end else begin
      // Dispatch
      if (dispatch_ready) begin
        // Dispatch Recieve
        rf_reorder[uoq_rd[uoq_tail][`YSYX_REG_LEN-1:0]] <= rob_tail;
        rf_busy[uoq_rd[uoq_tail][`YSYX_REG_LEN-1:0]] <= 1;

        rob_tail <= rob_tail + 1;
        rob_busy[rob_tail] <= 1;
        rob_rd[rob_tail] <= uoq_rd[uoq_tail];
        rob_inst[rob_tail] <= uoq_inst[uoq_tail];
        rob_state[rob_tail] <= EX;

        rob_pc[rob_tail] <= uoq_pc[uoq_tail];
        rob_pnpc[rob_tail] <= uoq_pnpc[uoq_tail];

        rob_f_i[rob_tail] <= uoq_f_i[uoq_tail];
        rob_f_time[rob_tail] <= uoq_f_time[uoq_tail];

        rob_rs_idx[rob_tail] <= exu_wb_if.rs_idx;
        rob_store[rob_tail] <= uoq_wen[uoq_tail];
      end
      // Write back
      if (exu_wb_if.valid) begin
        // Execute result get
        rob_state[wb_dest] <= WB;

        rob_value[wb_dest] <= exu_wb_if.result;
        rob_npc[wb_dest] <= exu_wb_if.npc;
        rob_sys[wb_dest] <= exu_wb_if.sys_retire;
        rob_br_retire[wb_dest] <= exu_wb_if.br_retire;
        rob_ebreak[wb_dest] <= exu_wb_if.ebreak;

        rob_csr_wen[wb_dest] <= exu_wb_if.csr_wen;
        rob_csr_wdata[wb_dest] <= exu_wb_if.csr_wdata;
        rob_csr_addr[wb_dest] <= exu_wb_if.csr_addr;
        rob_ecall[wb_dest] <= exu_wb_if.ecall;
        rob_mret[wb_dest] <= exu_wb_if.mret;
      end
      // Commit
      if (rob_busy[rob_head] && rob_state[rob_head] == WB) begin
        // Write result and commit
        rob_head <= rob_head + 1;

        rob_busy[rob_head] <= 0;
        rob_inst[rob_head] <= 0;
        rob_state[rob_head] <= CM;
        if (rf_reorder[rob_rd[rob_head][`YSYX_REG_LEN-1:0]] == rob_head) begin
          if (dispatch_ready && (uoq_rd[uoq_tail] == rob_rd[rob_head])) begin
          end else begin
            rf_busy[rob_rd[rob_head][`YSYX_REG_LEN-1:0]] <= 0;
          end
        end
        if ((rob_f_i[rob_head]) || (head_is_br && head_br_p_fail)) begin
          flush_pipeline <= 1;
        end
        if (rob_f_time[rob_head]) begin
          fence_time <= 1;
        end
      end
    end
  end

  assign head_is_br = (rob_br_retire[rob_head]);
  assign head_br_p_fail = rob_npc[rob_head] != rob_pnpc[rob_head];
  assign head_valid = rob_busy[rob_head] && rob_state[rob_head] == WB && !flush_pipeline;

  assign iqu_wbu_if.rd = rob_rd[rob_head];
  assign iqu_wbu_if.inst = rob_inst[rob_head];
  assign iqu_wbu_if.pc = rob_pc[rob_head];

  assign iqu_wbu_if.result = rob_value[rob_head];
  assign iqu_wbu_if.npc = rob_npc[rob_head];
  assign iqu_wbu_if.sys_retire = rob_sys[rob_head] && head_valid;
  assign iqu_wbu_if.ebreak = rob_ebreak[rob_head] && head_valid;
  assign iqu_wbu_if.fence_i = rob_f_i[rob_head] && head_valid;
  assign iqu_wbu_if.valid = head_valid;

  assign iqu_cm_if.pc = rob_pc[rob_head];
  assign iqu_cm_if.csr_wdata = rob_csr_wdata[rob_head];
  assign iqu_cm_if.csr_wen = rob_csr_wen[rob_head];
  assign iqu_cm_if.csr_addr = rob_csr_addr[rob_head];
  assign iqu_cm_if.ecall = rob_ecall[rob_head];
  assign iqu_cm_if.mret = rob_mret[rob_head];

  assign iqu_cm_if.sq_idx = rob_rs_idx[rob_head];
  assign iqu_cm_if.store_commit = head_valid && rob_store[rob_head] && !flush_pipeline;

  assign iqu_cm_if.valid = rob_busy[rob_head] && rob_state[rob_head] == WB && !flush_pipeline;
endmodule

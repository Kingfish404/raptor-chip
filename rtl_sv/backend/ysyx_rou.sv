`include "ysyx.svh"
`include "ysyx_if.svh"

module ysyx_rou #(
    parameter unsigned IIQ_SIZE = `YSYX_IIQ_SIZE,
    parameter unsigned ROB_SIZE = `YSYX_ROB_SIZE,
    parameter unsigned RNUM = `YSYX_REG_SIZE,
    parameter unsigned RLEN = `YSYX_REG_LEN,
    parameter unsigned PLEN = `YSYX_PHY_LEN,
    parameter unsigned XLEN = `YSYX_XLEN
) (
    input clock,

    rnu_rou_if.slave idu_rou,

    exu_prf_if.master exu_prf,
    rou_exu_if.master rou_exu,

    exu_rou_if.in exu_rou,
    exu_ioq_rou_if.in exu_ioq_rou,

    // commit
    rou_cmu_if.out rou_cmu,
    rou_csr_if.out rou_csr,
    rou_lsu_if.out rou_lsu,

    input reset
);
  typedef enum logic [1:0] {
    CM = 'b00,
    WB = 'b01,
    EX = 'b10
  } rob_state_t;

  logic valid, ready;
  logic flush_pipe;
  logic fence_time;

  // === micro-op queue (UOQ) ===
  logic [$clog2(IIQ_SIZE)-1:0] uoq_tail;
  logic [$clog2(IIQ_SIZE)-1:0] uoq_head;
  logic [IIQ_SIZE-1:0] uoq_valid;

  logic uoq_c[IIQ_SIZE];
  logic [4:0] uoq_alu[IIQ_SIZE];
  logic uoq_jen[IIQ_SIZE];
  logic uoq_ben[IIQ_SIZE];
  logic uoq_wen[IIQ_SIZE];
  logic uoq_ren[IIQ_SIZE];
  logic uoq_atom[IIQ_SIZE];

  logic uoq_system[IIQ_SIZE];
  logic uoq_ecall[IIQ_SIZE];
  logic uoq_ebreak[IIQ_SIZE];
  logic uoq_mret[IIQ_SIZE];
  logic [2:0] uoq_csr_csw[IIQ_SIZE];

  logic uoq_trap[IIQ_SIZE];
  logic [XLEN-1:0] uoq_tval[IIQ_SIZE];
  logic [XLEN-1:0] uoq_cause[IIQ_SIZE];

  logic uoq_f_i[IIQ_SIZE];
  logic uoq_f_time[IIQ_SIZE];

  logic [RLEN-1:0] uoq_rd[IIQ_SIZE];

  logic [PLEN-1:0] uoq_pr1[IIQ_SIZE];
  logic [PLEN-1:0] uoq_pr2[IIQ_SIZE];
  logic [PLEN-1:0] uoq_prd[IIQ_SIZE];
  logic [PLEN-1:0] uoq_prs[IIQ_SIZE];

  logic [XLEN-1:0] uoq_imm[IIQ_SIZE];
  logic [XLEN-1:0] uoq_op1[IIQ_SIZE];
  logic [XLEN-1:0] uoq_op2[IIQ_SIZE];

  logic [XLEN-1:0] uoq_pnpc[IIQ_SIZE];
  logic [31:0] uoq_inst[IIQ_SIZE];
  logic [XLEN-1:0] uoq_pc[IIQ_SIZE];
  // === micro-op queue (UOQ) ===

  logic dispatch_ready;

  // === re-order buffer (ROB) ===
  logic [$clog2(ROB_SIZE)-1:0] rob_head;
  logic [$clog2(ROB_SIZE)-1:0] rob_tail;

  logic [PLEN-1:0] rob_prd[ROB_SIZE];
  logic [PLEN-1:0] rob_prs[ROB_SIZE];

  logic [ROB_SIZE-1:0] rob_busy;
  logic [RLEN-1:0] rob_rd[ROB_SIZE];
  logic [31:0] rob_inst[ROB_SIZE];
  rob_state_t rob_state[ROB_SIZE];
  logic [XLEN-1:0] rob_pc[ROB_SIZE];
  logic [XLEN-1:0] rob_pnpc[ROB_SIZE];
  logic rob_jen[ROB_SIZE];
  logic rob_ben[ROB_SIZE];

  logic [XLEN-1:0] rob_npc[ROB_SIZE];
  logic rob_sys[ROB_SIZE];

  logic rob_csr_wen[ROB_SIZE];
  logic [XLEN-1:0] rob_csr_wdata[ROB_SIZE];
  logic [11:0] rob_csr_addr[ROB_SIZE];

  logic rob_ecall[ROB_SIZE];
  logic rob_ebreak[ROB_SIZE];
  logic rob_mret[ROB_SIZE];

  logic rob_trap[ROB_SIZE];
  logic [XLEN-1:0] rob_tval[ROB_SIZE];
  logic [XLEN-1:0] rob_cause[ROB_SIZE];

  logic rob_f_i[ROB_SIZE];
  logic rob_f_time[ROB_SIZE];

  logic rob_store[ROB_SIZE];
  logic [4:0] rob_alu[ROB_SIZE];
  logic [XLEN-1:0] rob_sq_waddr[ROB_SIZE];
  logic [XLEN-1:0] rob_sq_wdata[ROB_SIZE];
  // === re-order buffer (ROB) ===

  logic head_br_p_fail;
  logic head_valid;

  assign dispatch_ready = (rou_exu.ready && uoq_valid[uoq_tail] && rob_busy[rob_tail] == 0);

  assign valid = uoq_valid[uoq_tail] && (rob_busy[rob_tail] == 0);
  assign ready = uoq_valid[uoq_head] == 0;
  assign rou_exu.valid = valid;
  assign idu_rou.ready = ready;

  always @(posedge clock) begin
    if (reset || flush_pipe) begin
      uoq_head  <= 0;
      uoq_tail  <= 0;
      uoq_valid <= 0;
    end else begin
      if (idu_rou.valid && uoq_valid[uoq_head] == 0) begin
        // Issue to uoq
        uoq_head              <= uoq_head + 1;

        uoq_c[uoq_head]       <= idu_rou.c;
        uoq_alu[uoq_head]     <= idu_rou.alu;
        uoq_jen[uoq_head]     <= idu_rou.jen;
        uoq_ben[uoq_head]     <= idu_rou.ben;
        uoq_wen[uoq_head]     <= idu_rou.wen;
        uoq_ren[uoq_head]     <= idu_rou.ren;
        uoq_atom[uoq_head]    <= idu_rou.atom;

        uoq_system[uoq_head]  <= idu_rou.system;
        uoq_ecall[uoq_head]   <= idu_rou.ecall;
        uoq_ebreak[uoq_head]  <= idu_rou.ebreak;
        uoq_mret[uoq_head]    <= idu_rou.mret;
        uoq_csr_csw[uoq_head] <= idu_rou.csr_csw;

        uoq_trap[uoq_head]    <= idu_rou.trap;
        uoq_tval[uoq_head]    <= idu_rou.tval;
        uoq_cause[uoq_head]   <= idu_rou.cause;

        uoq_f_i[uoq_head]     <= idu_rou.f_i;
        uoq_f_time[uoq_head]  <= idu_rou.f_time;

        uoq_rd[uoq_head]      <= idu_rou.rd;

        uoq_pr1[uoq_head]     <= idu_rou.pr1;
        uoq_pr2[uoq_head]     <= idu_rou.pr2;
        uoq_prd[uoq_head]     <= idu_rou.prd;
        uoq_prs[uoq_head]     <= idu_rou.prs;

        uoq_imm[uoq_head]     <= idu_rou.imm;
        uoq_op1[uoq_head]     <= idu_rou.op1;
        uoq_op2[uoq_head]     <= idu_rou.op2;

        uoq_pnpc[uoq_head]    <= idu_rou.pnpc;
        uoq_inst[uoq_head]    <= idu_rou.inst;
        uoq_pc[uoq_head]      <= idu_rou.pc;

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

  assign exu_prf.pr1 = uoq_pr1[uoq_tail];
  assign exu_prf.pr2 = uoq_pr2[uoq_tail];
  always_comb begin
    // Dispatch connect
    rou_exu.c = uoq_c[uoq_tail];
    rou_exu.alu = uoq_alu[uoq_tail];
    rou_exu.jen = uoq_jen[uoq_tail];
    rou_exu.ben = uoq_ben[uoq_tail];
    rou_exu.wen = uoq_wen[uoq_tail];
    rou_exu.ren = uoq_ren[uoq_tail];
    rou_exu.atom = uoq_atom[uoq_tail];

    rou_exu.system = uoq_system[uoq_tail];
    rou_exu.ecall = uoq_ecall[uoq_tail];
    rou_exu.ebreak = uoq_ebreak[uoq_tail];
    rou_exu.mret = uoq_mret[uoq_tail];
    rou_exu.csr_csw = uoq_csr_csw[uoq_tail];

    rou_exu.trap = uoq_trap[uoq_tail];
    rou_exu.tval = uoq_tval[uoq_tail];
    rou_exu.cause = uoq_cause[uoq_tail];

    rou_exu.rd = uoq_rd[uoq_tail];
    rou_exu.imm = uoq_imm[uoq_tail];

    rou_exu.op1 = (uoq_pr1[uoq_tail] != 0
      ? (exu_prf.pv1_valid
        ? exu_prf.pv1
          : exu_ioq_rou.valid && exu_ioq_rou.prd == uoq_pr1[uoq_tail]
            ? exu_ioq_rou.result
            : exu_rou.result)
      : uoq_op1[uoq_tail]);
    rou_exu.op2 = (uoq_pr2[uoq_tail] != 0
      ? (exu_prf.pv2_valid
        ? exu_prf.pv2
          : exu_ioq_rou.valid && exu_ioq_rou.prd == uoq_pr2[uoq_tail]
            ? exu_ioq_rou.result
            : exu_rou.result)
      : uoq_op2[uoq_tail]);

    rou_exu.pr1 = (exu_prf.pv1_valid
      || (exu_ioq_rou.valid && exu_ioq_rou.prd == uoq_pr1[uoq_tail])
      || (exu_rou.valid && exu_rou.prd == uoq_pr1[uoq_tail])) ? 0 : uoq_pr1[uoq_tail];
    rou_exu.pr2 = (exu_prf.pv2_valid
      || (exu_ioq_rou.valid && exu_ioq_rou.prd == uoq_pr2[uoq_tail])
      || (exu_rou.valid && exu_rou.prd == uoq_pr2[uoq_tail])) ? 0 :uoq_pr2[uoq_tail];
    rou_exu.prd = uoq_prd[uoq_tail];
    rou_exu.prs = uoq_prs[uoq_tail];

    rou_exu.dest = {{1'h0}, {rob_tail}} + 'h1;

    rou_exu.inst = uoq_inst[uoq_tail];
    rou_exu.pc = uoq_pc[uoq_tail];
  end

  logic [$clog2(ROB_SIZE)-1:0] wb_dest;
  logic [$clog2(ROB_SIZE)-1:0] wb_dest_ioq;
  assign wb_dest = exu_rou.dest[$clog2(ROB_SIZE)-1:0] - 1;
  assign wb_dest_ioq = exu_ioq_rou.dest[$clog2(ROB_SIZE)-1:0] - 1;
  always @(posedge clock) begin
    if (reset || flush_pipe) begin
      rob_head <= 0;
      rob_tail <= 0;
      rob_busy <= 0;
      for (int i = 0; i < ROB_SIZE; i++) begin
        rob_state[i] <= CM;
        rob_inst[i]  <= 0;
      end
    end else begin
      // Dispatch
      if (dispatch_ready) begin
        // Dispatch Recieve
        rob_tail <= rob_tail + 1;

        rob_prd[rob_tail] <= uoq_prd[uoq_tail];
        rob_prs[rob_tail] <= uoq_prs[uoq_tail];

        rob_busy[rob_tail] <= 1;
        rob_rd[rob_tail] <= uoq_rd[uoq_tail];
        rob_inst[rob_tail] <= uoq_inst[uoq_tail];
        rob_state[rob_tail] <= EX;

        rob_pc[rob_tail] <= uoq_pc[uoq_tail];
        rob_pnpc[rob_tail] <= uoq_pnpc[uoq_tail];
        rob_ben[rob_tail] <= uoq_ben[uoq_tail];
        rob_jen[rob_tail] <= uoq_jen[uoq_tail];

        rob_store[rob_tail] <= uoq_wen[uoq_tail];
        rob_alu[rob_tail] <= uoq_atom[uoq_tail] ? `YSYX_WSTRB_SW : uoq_alu[uoq_tail];

        rob_sys[rob_tail] <= uoq_system[uoq_tail];

        rob_f_i[rob_tail] <= uoq_f_i[uoq_tail];
        rob_f_time[rob_tail] <= uoq_f_time[uoq_tail];

        rob_ecall[rob_tail] <= uoq_ecall[uoq_tail];
        rob_ebreak[rob_tail] <= uoq_ebreak[uoq_tail];
        rob_mret[rob_tail] <= uoq_mret[uoq_tail];

        rob_trap[rob_tail] <= uoq_trap[uoq_tail];
        rob_tval[rob_tail] <= uoq_tval[uoq_tail];
        rob_cause[rob_tail] <= uoq_cause[uoq_tail];
      end
      // Write back
      if (exu_ioq_rou.valid) begin
        rob_state[wb_dest_ioq] <= WB;

        rob_npc[wb_dest_ioq] <= exu_ioq_rou.npc;

        rob_sq_waddr[wb_dest_ioq] <= exu_ioq_rou.sq_waddr;
        rob_sq_wdata[wb_dest_ioq] <= exu_ioq_rou.sq_wdata;
      end
      if (exu_rou.valid) begin
        // Execute result get
        rob_state[wb_dest] <= WB;

        rob_npc[wb_dest] <= exu_rou.npc;

        rob_csr_wen[wb_dest] <= exu_rou.csr_wen;
        rob_csr_wdata[wb_dest] <= exu_rou.csr_wdata;
        rob_csr_addr[wb_dest] <= exu_rou.csr_addr;

        rob_ecall[wb_dest] <= exu_rou.ecall;
        rob_ebreak[wb_dest] <= exu_rou.ebreak;
        rob_mret[wb_dest] <= exu_rou.mret;

        rob_trap[wb_dest] <= exu_rou.trap;
        rob_tval[wb_dest] <= exu_rou.tval;
        rob_cause[wb_dest] <= exu_rou.cause;
      end
      // Commit
      if (head_valid) begin
        // Write result and commit
        rob_head <= rob_head + 1;

        rob_busy[rob_head] <= 0;
        rob_inst[rob_head] <= 0;
        rob_state[rob_head] <= CM;

        rob_csr_wen[rob_head] <= 0;

        rob_sys[rob_head] <= 0;
        rob_ecall[rob_head] <= 0;
        rob_ebreak[rob_head] <= 0;
        rob_mret[rob_head] <= 0;

        rob_trap[rob_head] <= 0;

        rob_store[rob_head] <= 0;
        rob_sq_waddr[rob_head] <= 0;
        rob_sq_wdata[rob_head] <= 0;
      end
    end
  end

  assign head_br_p_fail = rob_npc[rob_head] != rob_pnpc[rob_head];
  assign head_valid = rob_busy[rob_head] && rob_state[rob_head] == WB
        && (rou_lsu.sq_ready || !rob_store[rob_head]);

  assign rou_cmu.rd = rob_rd[rob_head];
  assign rou_cmu.inst = rob_inst[rob_head];
  assign rou_cmu.pc = rob_pc[rob_head];

  assign rou_cmu.npc = rob_npc[rob_head];
  assign rou_cmu.jen = rob_jen[rob_head];
  assign rou_cmu.ben = rob_ben[rob_head];

  assign fence_time = head_valid && rob_f_time[rob_head];
  assign flush_pipe = head_valid && ((0)
    || (rob_f_i[rob_head])
    || (head_br_p_fail)
    || (rob_trap[rob_head])
    || (rob_sys[rob_head])
  );

  assign rou_cmu.ebreak = head_valid && rob_ebreak[rob_head];
  assign rou_cmu.fence_time = fence_time;
  assign rou_cmu.fence_i = head_valid && rob_f_i[rob_head];
  assign rou_cmu.flush_pipe = flush_pipe;
  assign rou_cmu.prd = rob_prd[rob_head];
  assign rou_cmu.prs = rob_prs[rob_head];

  assign rou_cmu.valid = head_valid;

  assign rou_csr.pc = rob_pc[rob_head];
  assign rou_csr.csr_wen = rob_csr_wen[rob_head];
  assign rou_csr.csr_wdata = rob_csr_wdata[rob_head];
  assign rou_csr.csr_addr = rob_csr_addr[rob_head];
  assign rou_csr.ecall = rob_ecall[rob_head];
  assign rou_csr.ebreak = rob_ebreak[rob_head];
  assign rou_csr.mret = rob_mret[rob_head];

  assign rou_csr.trap = rob_trap[rob_head];
  assign rou_csr.tval = rob_tval[rob_head];
  assign rou_csr.cause = rob_cause[rob_head];
  assign rou_csr.valid = head_valid && rob_sys[rob_head];

  assign rou_lsu.store = rob_store[rob_head];
  assign rou_lsu.alu = rob_alu[rob_head];
  assign rou_lsu.sq_waddr = rob_sq_waddr[rob_head];
  assign rou_lsu.sq_wdata = rob_sq_wdata[rob_head];
  assign rou_lsu.pc = rob_pc[rob_head];
  assign rou_lsu.valid = head_valid;

endmodule

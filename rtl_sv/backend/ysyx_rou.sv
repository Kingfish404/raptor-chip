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

    rnu_rou_if.slave rnu_rou,

    exu_prf_if.master exu_prf,
    rou_exu_if.master rou_exu,

    exu_rou_if.in exu_rou,
    exu_ioq_bcast_if.in exu_ioq_bcast,

    // interrupt
    csr_bcast_if.in csr_bcast,
    input clint_trap,

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

  // async trap
  logic recieved_trap;
  logic [XLEN-1:0] trap_pc;

  // === micro-op queue (UOQ) ===
  logic [$clog2(IIQ_SIZE)-1:0] uoq_tail;
  logic [$clog2(IIQ_SIZE)-1:0] uoq_head;
  logic [IIQ_SIZE-1:0] uoq_valid;

  ysyx_pkg::uop_t uops[IIQ_SIZE];

  logic [PLEN-1:0] uoq_pr1[IIQ_SIZE];
  logic [PLEN-1:0] uoq_pr2[IIQ_SIZE];
  logic [PLEN-1:0] uoq_prd[IIQ_SIZE];
  logic [PLEN-1:0] uoq_prs[IIQ_SIZE];

  logic [XLEN-1:0] uoq_op1[IIQ_SIZE];
  logic [XLEN-1:0] uoq_op2[IIQ_SIZE];
  // === micro-op queue (UOQ) ===

  logic dispatch_ready;

  // === re-order buffer (ROB) ===
  logic [$clog2(ROB_SIZE)-1:0] rob_head;
  logic [$clog2(ROB_SIZE)-1:0] rob_tail;

  logic [PLEN-1:0] rob_prd[ROB_SIZE];
  logic [PLEN-1:0] rob_prs[ROB_SIZE];

  logic [ROB_SIZE-1:0] rob_busy;
  logic [RLEN-1:0] rob_rd[ROB_SIZE];
  rob_state_t rob_state[ROB_SIZE];
  logic rob_ben[ROB_SIZE];
  logic rob_jen[ROB_SIZE];
  logic rob_jren[ROB_SIZE];

  logic [XLEN-1:0] rob_npc[ROB_SIZE];
  logic rob_sys[ROB_SIZE];
  logic rob_atom[ROB_SIZE];
  logic rob_atom_sc[ROB_SIZE];

  logic rob_csr_wen[ROB_SIZE];
  logic [XLEN-1:0] rob_csr_wdata[ROB_SIZE];
  logic [11:0] rob_csr_addr[ROB_SIZE];

  logic rob_ecall[ROB_SIZE];
  logic rob_ebreak[ROB_SIZE];
  logic rob_mret[ROB_SIZE];
  logic rob_sret[ROB_SIZE];

  logic rob_trap[ROB_SIZE];
  logic [XLEN-1:0] rob_tval[ROB_SIZE];
  logic [XLEN-1:0] rob_cause[ROB_SIZE];

  logic rob_f_i[ROB_SIZE];
  logic rob_f_time[ROB_SIZE];

  logic rob_btaken[ROB_SIZE];
  logic [XLEN-1:0] rob_pnpc[ROB_SIZE];
  logic [31:0] rob_inst[ROB_SIZE];
  logic [XLEN-1:0] rob_pc[ROB_SIZE];

  logic rob_wen[ROB_SIZE];
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
  assign rnu_rou.ready = ready;

  always @(posedge clock) begin
    if (reset || flush_pipe) begin
      uoq_head  <= 0;
      uoq_tail  <= 0;
      uoq_valid <= 0;
    end else begin
      if (rnu_rou.valid && uoq_valid[uoq_head] == 0) begin
        // Issue to uoq
        uoq_head            <= uoq_head + 1;

        uops[uoq_head]      <= rnu_rou.uop;

        uoq_pr1[uoq_head]   <= rnu_rou.pr1;
        uoq_pr2[uoq_head]   <= rnu_rou.pr2;
        uoq_prd[uoq_head]   <= rnu_rou.prd;
        uoq_prs[uoq_head]   <= rnu_rou.prs;

        uoq_op1[uoq_head]   <= rnu_rou.op1;
        uoq_op2[uoq_head]   <= rnu_rou.op2;

        uoq_valid[uoq_head] <= 1;
      end
      if (dispatch_ready) begin
        // Dispatch to exu and rob
        uoq_tail <= uoq_tail + 1;
        uoq_valid[uoq_tail] <= 0;
      end
    end
  end

  assign exu_prf.pr1 = uoq_pr1[uoq_tail];
  assign exu_prf.pr2 = uoq_pr2[uoq_tail];
  always_comb begin
    // Dispatch connect
    rou_exu.uop = uops[uoq_tail];

    rou_exu.op1 = (uoq_pr1[uoq_tail] != 0
      ? (exu_prf.pv1_valid
        ? exu_prf.pv1
        : exu_ioq_bcast.valid && exu_ioq_bcast.prd == uoq_pr1[uoq_tail]
          ? exu_ioq_bcast.result
          : exu_rou.result)
      : uoq_op1[uoq_tail]);
    rou_exu.op2 = (uoq_pr2[uoq_tail] != 0
      ? (exu_prf.pv2_valid
        ? exu_prf.pv2
        : exu_ioq_bcast.valid && exu_ioq_bcast.prd == uoq_pr2[uoq_tail]
          ? exu_ioq_bcast.result
          : exu_rou.result)
      : uoq_op2[uoq_tail]);

    rou_exu.pr1 = (exu_prf.pv1_valid
      || (exu_ioq_bcast.valid && exu_ioq_bcast.prd == uoq_pr1[uoq_tail])
      || (exu_rou.valid && exu_rou.prd == uoq_pr1[uoq_tail])) ? 0 : uoq_pr1[uoq_tail];
    rou_exu.pr2 = (exu_prf.pv2_valid
      || (exu_ioq_bcast.valid && exu_ioq_bcast.prd == uoq_pr2[uoq_tail])
      || (exu_rou.valid && exu_rou.prd == uoq_pr2[uoq_tail])) ? 0 :uoq_pr2[uoq_tail];
    rou_exu.prd = uoq_prd[uoq_tail];
    rou_exu.prs = uoq_prs[uoq_tail];

    rou_exu.dest = {{1'h0}, {rob_tail}} + 'h1;
  end

  logic [$clog2(ROB_SIZE)-1:0] wb_dest;
  logic [$clog2(ROB_SIZE)-1:0] wb_dest_ioq;
  assign wb_dest = exu_rou.dest[$clog2(ROB_SIZE)-1:0] - 1;
  assign wb_dest_ioq = exu_ioq_bcast.dest[$clog2(ROB_SIZE)-1:0] - 1;
  always @(posedge clock) begin
    if (reset || flush_pipe) begin
      rob_head <= 0;
      rob_tail <= 0;
      rob_busy <= 0;
      for (int i = 0; i < ROB_SIZE; i++) begin
        rob_state[i] <= CM;
        rob_inst[i]  <= 0;
      end
      recieved_trap <= 0;
    end else begin
      // Dispatch
      if (dispatch_ready) begin
        // Dispatch Recieve
        rob_tail <= rob_tail + 1;

        rob_prd[rob_tail] <= uoq_prd[uoq_tail];
        rob_prs[rob_tail] <= uoq_prs[uoq_tail];

        rob_busy[rob_tail] <= 1;
        rob_state[rob_tail] <= EX;
        rob_rd[rob_tail] <= uops[uoq_tail].rd;

        rob_ben[rob_tail] <= uops[uoq_tail].ben;
        rob_jen[rob_tail] <= uops[uoq_tail].jen;
        rob_jren[rob_tail] <= uops[uoq_tail].jren;

        rob_wen[rob_tail] <= uops[uoq_tail].wen;
        rob_alu[rob_tail] <= uops[uoq_tail].atom ? `YSYX_WSTRB_SW : uops[uoq_tail].alu;

        rob_sys[rob_tail] <= uops[uoq_tail].system;

        rob_atom[rob_tail] <= uops[uoq_tail].atom;
        rob_atom_sc[rob_tail] <= uops[uoq_tail].atom && (uops[uoq_tail].alu == `YSYX_ATO_SC__);

        rob_f_i[rob_tail] <= uops[uoq_tail].f_i;
        rob_f_time[rob_tail] <= uops[uoq_tail].f_time;

        rob_ecall[rob_tail] <= uops[uoq_tail].ecall;
        rob_ebreak[rob_tail] <= uops[uoq_tail].ebreak;
        rob_mret[rob_tail] <= uops[uoq_tail].mret;
        rob_sret[rob_tail] <= uops[uoq_tail].sret;

        rob_trap[rob_tail] <= uops[uoq_tail].trap;
        rob_tval[rob_tail] <= uops[uoq_tail].tval;
        rob_cause[rob_tail] <= uops[uoq_tail].cause;

        rob_inst[rob_tail] <= uops[uoq_tail].inst;
        rob_pnpc[rob_tail] <= uops[uoq_tail].pnpc;
        rob_pc[rob_tail] <= uops[uoq_tail].pc;
      end
      // Write back
      if (exu_ioq_bcast.valid) begin
        rob_state[wb_dest_ioq] <= WB;

        rob_npc[wb_dest_ioq] <= exu_ioq_bcast.npc;

        rob_wen[wb_dest_ioq] <= exu_ioq_bcast.wen;
        rob_sq_waddr[wb_dest_ioq] <= exu_ioq_bcast.sq_waddr;
        rob_sq_wdata[wb_dest_ioq] <= exu_ioq_bcast.sq_wdata;

        if (exu_ioq_bcast.trap) begin
          rob_rd[wb_dest_ioq]   <= 0;
          rob_inst[wb_dest_ioq] <= 'h13;
          rob_wen[wb_dest_ioq]  <= 0;
        end

        rob_trap[wb_dest_ioq]  <= exu_ioq_bcast.trap;
        rob_tval[wb_dest_ioq]  <= exu_ioq_bcast.tval;
        rob_cause[wb_dest_ioq] <= exu_ioq_bcast.cause;
        rob_inst[wb_dest_ioq]  <= exu_ioq_bcast.inst;
      end
      if (exu_rou.valid) begin
        // Execute result get
        rob_state[wb_dest] <= WB;

        rob_btaken[wb_dest] <= exu_rou.btaken;
        rob_npc[wb_dest] <= exu_rou.npc;

        rob_csr_wen[wb_dest] <= exu_rou.csr_wen;
        rob_csr_wdata[wb_dest] <= exu_rou.csr_wdata;
        rob_csr_addr[wb_dest] <= exu_rou.csr_addr;

        rob_ecall[wb_dest] <= exu_rou.ecall;
        rob_ebreak[wb_dest] <= exu_rou.ebreak;
        rob_mret[wb_dest] <= exu_rou.mret;
        rob_sret[wb_dest] <= exu_rou.sret;

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

        rob_wen[rob_head] <= 0;
        rob_sq_waddr[rob_head] <= 0;
        rob_sq_wdata[rob_head] <= 0;

        recieved_trap <= clint_trap;
        trap_pc <= rob_npc[rob_head];
      end
    end
  end

  assign head_br_p_fail = rob_npc[rob_head] != rob_pnpc[rob_head];
  assign head_valid = recieved_trap || (
      rob_busy[rob_head]
      && rob_state[rob_head] == WB
      && (rou_lsu.sq_ready || !rob_wen[rob_head]));

  assign rou_cmu.rd = recieved_trap ? 'h0 : rob_rd[rob_head];
  assign rou_cmu.inst = rob_inst[rob_head];
  assign rou_cmu.pc = recieved_trap ? trap_pc : rob_pc[rob_head];

  assign rou_cmu.prd = rob_prd[rob_head];
  assign rou_cmu.prs = rob_prs[rob_head];

  assign rou_cmu.btaken = rob_btaken[rob_head];
  assign rou_cmu.npc = recieved_trap || rob_trap[rob_head] ? csr_bcast.tvec : rob_npc[rob_head];
  assign rou_cmu.ben = rob_ben[rob_head];
  assign rou_cmu.jen = rob_jen[rob_head];
  assign rou_cmu.jren = rob_jren[rob_head];
  assign rou_cmu.atomic_sc = rob_atom_sc[rob_head];

  assign fence_time = head_valid && rob_f_time[rob_head];
  assign flush_pipe = recieved_trap || (head_valid && ((0)
    || (rob_f_i[rob_head])
    || (head_br_p_fail)
    || (rob_trap[rob_head])
    || (rob_sys[rob_head])
    || (rob_atom[rob_head])
  ));

  assign rou_cmu.ebreak = head_valid && rob_ebreak[rob_head];
  assign rou_cmu.fence_time = fence_time;
  assign rou_cmu.fence_i = head_valid && rob_f_i[rob_head];
  assign rou_cmu.flush_pipe = flush_pipe;
  assign rou_cmu.time_trap = recieved_trap;

  assign rou_cmu.valid = recieved_trap ? 'h0 : head_valid;

  assign rou_csr.pc = recieved_trap ? trap_pc : rob_pc[rob_head];
  assign rou_csr.csr_wen = recieved_trap ? 'h0 : rob_csr_wen[rob_head];
  assign rou_csr.csr_wdata = rob_csr_wdata[rob_head];
  assign rou_csr.csr_addr = rob_csr_addr[rob_head];
  assign rou_csr.ecall = recieved_trap ? 'h0 : rob_ecall[rob_head];
  assign rou_csr.ebreak = recieved_trap ? 'h0 : rob_ebreak[rob_head];
  assign rou_csr.mret = recieved_trap ? 'h0 : rob_mret[rob_head];
  assign rou_csr.sret = recieved_trap ? 'h0 : rob_sret[rob_head];

  assign rou_csr.trap = recieved_trap || rob_trap[rob_head];
  assign rou_csr.tval = recieved_trap ? trap_pc : rob_tval[rob_head];
  assign rou_csr.cause = recieved_trap
    ? ((csr_bcast.priv == `YSYX_PRIV_M) ? 'h7 : 'h5) + ('b1 << (XLEN-1))
    : rob_cause[rob_head];
  assign rou_csr.valid = recieved_trap || (head_valid && (rob_sys[rob_head] || rob_trap[rob_head]));

  assign rou_lsu.store = recieved_trap ? 'h0 : rob_wen[rob_head];
  assign rou_lsu.alu = rob_alu[rob_head];
  assign rou_lsu.sq_waddr = rob_sq_waddr[rob_head];
  assign rou_lsu.sq_wdata = rob_sq_wdata[rob_head];
  assign rou_lsu.pc = rob_pc[rob_head];
  assign rou_lsu.valid = head_valid;

endmodule

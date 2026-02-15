`include "ysyx.svh"
`include "ysyx_if.svh"
import ysyx_pkg::*;

// Re-Order Unit (ROU) - dispatch queue + reorder buffer + commit.
//
// Sub-sections:
//   1. Dispatch Queue (UOQ)  - buffers renamed uops before ROB insertion
//   2. Reorder Buffer (ROB)  - tracks in-flight instructions for in-order commit
//   3. Operand Bypass         - forwards results from EXU/IOQ to dispatch
//   4. Commit Logic           - retires ROB head when ready
//
// Parameters sized for single-issue; ISSUE_WIDTH controls dispatch/commit width.
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
  logic valid, ready;
  logic flush_pipe;
  logic fence_time;

  // Async trap state
  logic           recieved_trap;
  logic [XLEN-1:0] trap_pc;

  // ================================================================
  // 1. Dispatch Queue (UOQ)
  // ================================================================
  logic [$clog2(IIQ_SIZE)-1:0] uoq_head, uoq_tail;
  logic [IIQ_SIZE-1:0]        uoq_valid;

  ysyx_pkg::uop_t             uoq_uops [IIQ_SIZE];
  logic [PLEN-1:0]            uoq_pr1  [IIQ_SIZE];
  logic [PLEN-1:0]            uoq_pr2  [IIQ_SIZE];
  logic [PLEN-1:0]            uoq_prd  [IIQ_SIZE];
  logic [PLEN-1:0]            uoq_prs  [IIQ_SIZE];
  logic [XLEN-1:0]            uoq_op1  [IIQ_SIZE];
  logic [XLEN-1:0]            uoq_op2  [IIQ_SIZE];

  logic uoq_enq_fire, uoq_deq_fire;
  assign uoq_enq_fire = rnu_rou.valid && !uoq_valid[uoq_head];
  assign uoq_deq_fire = rou_exu.ready && uoq_valid[uoq_tail] && !rob_entry[rob_tail].busy;

  assign valid         = uoq_valid[uoq_tail] && !rob_entry[rob_tail].busy;
  assign ready         = !uoq_valid[uoq_head];
  assign rou_exu.valid = valid;
  assign rnu_rou.ready = ready;

  always @(posedge clock) begin
    if (reset || flush_pipe) begin
      uoq_head  <= '0;
      uoq_tail  <= '0;
      uoq_valid <= '0;
    end else begin
      if (uoq_enq_fire) begin
        uoq_head            <= uoq_head + 1;
        uoq_valid[uoq_head] <= 1'b1;
        uoq_uops[uoq_head]  <= rnu_rou.uop;
        uoq_pr1[uoq_head]   <= rnu_rou.pr1;
        uoq_pr2[uoq_head]   <= rnu_rou.pr2;
        uoq_prd[uoq_head]   <= rnu_rou.prd;
        uoq_prs[uoq_head]   <= rnu_rou.prs;
        uoq_op1[uoq_head]   <= rnu_rou.op1;
        uoq_op2[uoq_head]   <= rnu_rou.op2;
      end
      if (uoq_deq_fire) begin
        uoq_tail            <= uoq_tail + 1;
        uoq_valid[uoq_tail] <= 1'b0;
      end
    end
  end

  // ================================================================
  // 2. Operand Bypass & Dispatch
  // ================================================================
  // PRF read addresses
  assign exu_prf.pr1 = uoq_pr1[uoq_tail];
  assign exu_prf.pr2 = uoq_pr2[uoq_tail];

  // Bypass: check EXU and IOQ broadcast for operand forwarding
  logic pr1_from_prf, pr1_from_ioq, pr1_from_exu;
  logic pr2_from_prf, pr2_from_ioq, pr2_from_exu;

  assign pr1_from_prf = exu_prf.pv1_valid;
  assign pr1_from_ioq = exu_ioq_bcast.valid && (exu_ioq_bcast.prd == uoq_pr1[uoq_tail]);
  assign pr1_from_exu = exu_rou.valid && (exu_rou.prd == uoq_pr1[uoq_tail]);

  assign pr2_from_prf = exu_prf.pv2_valid;
  assign pr2_from_ioq = exu_ioq_bcast.valid && (exu_ioq_bcast.prd == uoq_pr2[uoq_tail]);
  assign pr2_from_exu = exu_rou.valid && (exu_rou.prd == uoq_pr2[uoq_tail]);

  logic pr1_ready, pr2_ready;
  assign pr1_ready = pr1_from_prf || pr1_from_ioq || pr1_from_exu;
  assign pr2_ready = pr2_from_prf || pr2_from_ioq || pr2_from_exu;

  always_comb begin
    rou_exu.uop = uoq_uops[uoq_tail];

    // Operand 1 selection (priority: PRF > IOQ bypass > EXU bypass > immediate)
    rou_exu.op1 = (uoq_pr1[uoq_tail] != 0)
        ? (pr1_from_prf ? exu_prf.pv1
         : pr1_from_ioq ? exu_ioq_bcast.result
         :                exu_rou.result)
        : uoq_op1[uoq_tail];

    // Operand 2 selection
    rou_exu.op2 = (uoq_pr2[uoq_tail] != 0)
        ? (pr2_from_prf ? exu_prf.pv2
         : pr2_from_ioq ? exu_ioq_bcast.result
         :                exu_rou.result)
        : uoq_op2[uoq_tail];

    // Physical register IDs (zero if operand is ready = no scoreboard stall)
    rou_exu.pr1 = pr1_ready ? '0 : uoq_pr1[uoq_tail];
    rou_exu.pr2 = pr2_ready ? '0 : uoq_pr2[uoq_tail];
    rou_exu.prd = uoq_prd[uoq_tail];
    rou_exu.prs = uoq_prs[uoq_tail];

    // ROB destination tag (1-indexed)
    rou_exu.dest = {{1'b0}, rob_tail} + 1;
  end

  // ================================================================
  // 3. Reorder Buffer (ROB) - uses rob_entry_t struct array
  // ================================================================
  logic [$clog2(ROB_SIZE)-1:0] rob_head, rob_tail;
  ysyx_pkg::rob_entry_t rob_entry [ROB_SIZE];

  // Write-back destination index decoding
  logic [$clog2(ROB_SIZE)-1:0] wb_dest_exu, wb_dest_ioq;
  assign wb_dest_exu = exu_rou.dest[$clog2(ROB_SIZE)-1:0] - 1;
  assign wb_dest_ioq = exu_ioq_bcast.dest[$clog2(ROB_SIZE)-1:0] - 1;

  always @(posedge clock) begin
    if (reset || flush_pipe) begin
      rob_head      <= '0;
      rob_tail      <= '0;
      recieved_trap <= 1'b0;
      for (int i = 0; i < ROB_SIZE; i++) begin
        rob_entry[i].busy  <= 1'b0;
        rob_entry[i].state <= ROB_CM;
        rob_entry[i].inst  <= '0;
      end
    end else begin
      // ---- Dispatch: insert into ROB tail ----
      if (uoq_deq_fire) begin
        rob_tail <= rob_tail + 1;

        rob_entry[rob_tail].prd    <= uoq_prd[uoq_tail];
        rob_entry[rob_tail].prs    <= uoq_prs[uoq_tail];
        rob_entry[rob_tail].busy   <= 1'b1;
        rob_entry[rob_tail].state  <= ROB_EX;
        rob_entry[rob_tail].rd     <= uoq_uops[uoq_tail].rd;

        rob_entry[rob_tail].ben    <= uoq_uops[uoq_tail].ben;
        rob_entry[rob_tail].jen    <= uoq_uops[uoq_tail].jen;
        rob_entry[rob_tail].jren   <= uoq_uops[uoq_tail].jren;
        rob_entry[rob_tail].pnpc   <= uoq_uops[uoq_tail].pnpc;

        rob_entry[rob_tail].wen    <= uoq_uops[uoq_tail].wen;
        rob_entry[rob_tail].alu    <= uoq_uops[uoq_tail].atom ? `YSYX_WSTRB_SW
                                                               : uoq_uops[uoq_tail].alu;

        rob_entry[rob_tail].sys    <= uoq_uops[uoq_tail].system;
        rob_entry[rob_tail].atom   <= uoq_uops[uoq_tail].atom;
        rob_entry[rob_tail].atom_sc <= uoq_uops[uoq_tail].atom
                                    && (uoq_uops[uoq_tail].alu == `YSYX_ATO_SC__);

        rob_entry[rob_tail].f_i    <= uoq_uops[uoq_tail].f_i;
        rob_entry[rob_tail].f_time <= uoq_uops[uoq_tail].f_time;

        rob_entry[rob_tail].ecall  <= uoq_uops[uoq_tail].ecall;
        rob_entry[rob_tail].ebreak <= uoq_uops[uoq_tail].ebreak;
        rob_entry[rob_tail].mret   <= uoq_uops[uoq_tail].mret;
        rob_entry[rob_tail].sret   <= uoq_uops[uoq_tail].sret;

        rob_entry[rob_tail].trap   <= uoq_uops[uoq_tail].trap;
        rob_entry[rob_tail].tval   <= uoq_uops[uoq_tail].tval;
        rob_entry[rob_tail].cause  <= uoq_uops[uoq_tail].cause;

        rob_entry[rob_tail].inst   <= uoq_uops[uoq_tail].inst;
        rob_entry[rob_tail].pc     <= uoq_uops[uoq_tail].pc;
      end

      // ---- Write-back from IOQ (load/store completion) ----
      if (exu_ioq_bcast.valid) begin
        rob_entry[wb_dest_ioq].state     <= ROB_WB;
        rob_entry[wb_dest_ioq].npc       <= exu_ioq_bcast.npc;
        rob_entry[wb_dest_ioq].wen       <= exu_ioq_bcast.wen;
        rob_entry[wb_dest_ioq].sq_waddr  <= exu_ioq_bcast.sq_waddr;
        rob_entry[wb_dest_ioq].sq_wdata  <= exu_ioq_bcast.sq_wdata;

        if (exu_ioq_bcast.trap) begin
          rob_entry[wb_dest_ioq].rd   <= '0;
          rob_entry[wb_dest_ioq].inst <= 'h13;
          rob_entry[wb_dest_ioq].wen  <= 1'b0;
        end

        rob_entry[wb_dest_ioq].trap   <= exu_ioq_bcast.trap;
        rob_entry[wb_dest_ioq].tval   <= exu_ioq_bcast.tval;
        rob_entry[wb_dest_ioq].cause  <= exu_ioq_bcast.cause;
        rob_entry[wb_dest_ioq].inst   <= exu_ioq_bcast.inst;
      end

      // ---- Write-back from EXU (ALU/branch completion) ----
      if (exu_rou.valid) begin
        rob_entry[wb_dest_exu].state     <= ROB_WB;
        rob_entry[wb_dest_exu].btaken    <= exu_rou.btaken;
        rob_entry[wb_dest_exu].npc       <= exu_rou.npc;

        rob_entry[wb_dest_exu].csr_wen   <= exu_rou.csr_wen;
        rob_entry[wb_dest_exu].csr_wdata <= exu_rou.csr_wdata;
        rob_entry[wb_dest_exu].csr_addr  <= exu_rou.csr_addr;

        rob_entry[wb_dest_exu].ecall     <= exu_rou.ecall;
        rob_entry[wb_dest_exu].ebreak    <= exu_rou.ebreak;
        rob_entry[wb_dest_exu].mret      <= exu_rou.mret;
        rob_entry[wb_dest_exu].sret      <= exu_rou.sret;

        rob_entry[wb_dest_exu].trap      <= exu_rou.trap;
        rob_entry[wb_dest_exu].tval      <= exu_rou.tval;
        rob_entry[wb_dest_exu].cause     <= exu_rou.cause;
      end

      // ---- Commit: retire ROB head ----
      if (head_valid) begin
        rob_head <= rob_head + 1;

        rob_entry[rob_head].busy     <= 1'b0;
        rob_entry[rob_head].state    <= ROB_CM;
        rob_entry[rob_head].inst     <= '0;
        rob_entry[rob_head].csr_wen  <= 1'b0;
        rob_entry[rob_head].sys      <= 1'b0;
        rob_entry[rob_head].ecall    <= 1'b0;
        rob_entry[rob_head].ebreak   <= 1'b0;
        rob_entry[rob_head].mret     <= 1'b0;
        rob_entry[rob_head].trap     <= 1'b0;
        rob_entry[rob_head].wen      <= 1'b0;
        rob_entry[rob_head].sq_waddr <= '0;
        rob_entry[rob_head].sq_wdata <= '0;

        recieved_trap <= clint_trap;
        trap_pc       <= rob_entry[rob_head].npc;
      end
    end
  end

  // ================================================================
  // 4. Commit Logic
  // ================================================================
  // Aliases for ROB head entry (readability)
  wire [$clog2(ROB_SIZE)-1:0] h = rob_head;

  logic head_br_p_fail;
  logic head_valid;

  assign head_br_p_fail = rob_entry[h].npc != rob_entry[h].pnpc;
  assign head_valid     = recieved_trap || (
      rob_entry[h].busy
      && rob_entry[h].state == ROB_WB
      && (rou_lsu.sq_ready || !rob_entry[h].wen));

  // ---- Flush determination ----
  assign fence_time = head_valid && rob_entry[h].f_time;
  assign flush_pipe = recieved_trap || (head_valid && (
      rob_entry[h].f_i
      || head_br_p_fail
      || rob_entry[h].trap
      || rob_entry[h].sys
      || rob_entry[h].atom
  ));

  // ---- CMU interface ----
  assign rou_cmu.rd         = recieved_trap ? '0          : rob_entry[h].rd;
  assign rou_cmu.inst       = rob_entry[h].inst;
  assign rou_cmu.pc         = recieved_trap ? trap_pc     : rob_entry[h].pc;
  assign rou_cmu.prd        = rob_entry[h].prd;
  assign rou_cmu.prs        = rob_entry[h].prs;
  assign rou_cmu.btaken     = rob_entry[h].btaken;
  assign rou_cmu.npc        = (recieved_trap || rob_entry[h].trap) ? csr_bcast.tvec
                                                                   : rob_entry[h].npc;
  assign rou_cmu.ben        = rob_entry[h].ben;
  assign rou_cmu.jen        = rob_entry[h].jen;
  assign rou_cmu.jren       = rob_entry[h].jren;
  assign rou_cmu.atomic_sc  = rob_entry[h].atom_sc;
  assign rou_cmu.ebreak     = head_valid && rob_entry[h].ebreak;
  assign rou_cmu.fence_time = fence_time;
  assign rou_cmu.fence_i    = head_valid && rob_entry[h].f_i;
  assign rou_cmu.flush_pipe = flush_pipe;
  assign rou_cmu.time_trap  = recieved_trap;
  assign rou_cmu.valid      = recieved_trap ? 1'b0 : head_valid;

  // ---- CSR interface ----
  assign rou_csr.pc        = recieved_trap ? trap_pc : rob_entry[h].pc;
  assign rou_csr.csr_wen   = recieved_trap ? 1'b0   : rob_entry[h].csr_wen;
  assign rou_csr.csr_wdata = rob_entry[h].csr_wdata;
  assign rou_csr.csr_addr  = rob_entry[h].csr_addr;
  assign rou_csr.ecall     = recieved_trap ? 1'b0    : rob_entry[h].ecall;
  assign rou_csr.ebreak    = recieved_trap ? 1'b0    : rob_entry[h].ebreak;
  assign rou_csr.mret      = recieved_trap ? 1'b0    : rob_entry[h].mret;
  assign rou_csr.sret      = recieved_trap ? 1'b0    : rob_entry[h].sret;
  assign rou_csr.trap      = recieved_trap || rob_entry[h].trap;
  assign rou_csr.tval      = recieved_trap ? trap_pc : rob_entry[h].tval;
  assign rou_csr.cause     = recieved_trap
      ? ((csr_bcast.priv == `YSYX_PRIV_M) ? 'h7 : 'h5) + ('b1 << (XLEN - 1))
      : rob_entry[h].cause;
  assign rou_csr.valid     = recieved_trap || (head_valid && (rob_entry[h].sys || rob_entry[h].trap));

  // ---- LSU interface (store commit) ----
  assign rou_lsu.store     = recieved_trap ? 1'b0 : rob_entry[h].wen;
  assign rou_lsu.alu       = rob_entry[h].alu;
  assign rou_lsu.sq_waddr  = rob_entry[h].sq_waddr;
  assign rou_lsu.sq_wdata  = rob_entry[h].sq_wdata;
  assign rou_lsu.pc        = rob_entry[h].pc;
  assign rou_lsu.valid     = head_valid;

endmodule

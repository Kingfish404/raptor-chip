`include "rapt.svh"
`include "rapt_if.svh"

// MUL/DIV pipeline (4th execution pipe): private issue queue + MUL/DIV FU
// + dedicated CDB writeback port.
//
// Phase 1 of the execution-engine decoupling: carve the multiplier out of
// the unified RS so MUL/DIV uops no longer occupy RS entries for their
// whole latency nor consume an ALU-CSR issue slot at completion.
//
// Responsibilities:
//   * Buffer dispatched MUL/DIV uops with operands (small age-ordered IQ)
//   * Wake operands from the typed completion array (integer / MEM / self).
//     No fast load-use path here: a load-fed MUL wakes one cycle later on
//     the confirming MEM broadcast, trading a cycle of mul latency for a
//     narrow wakeup network.
//   * Feed the tag-based rapt_ieu_mul FU (pipelined MUL, iterative DIV)
//   * Drive the `exu_wb_mul` CDB port straight from the FU's registered
//     outputs (dest/prd/rd looked up by tag)
//
// A uop is routed here only if it is pure MUL/DIV arithmetic
// (see `a_to_mdq` in rapt_dpu): never memory / system / trap / branch,
// so this pipe carries no CSR, trap, or store sideband (tied 0).
module rapt_ieu_muldiv #(
    parameter rapt_pkg::core_config_t Cfg = rapt_pkg::CoreConfig,
    parameter type SlotT = rapt_pkg::dispatch_slot_t,
    parameter int unsigned NumSlots = Cfg.dispatch_width,
    parameter int unsigned NumCompletions = Cfg.completion_ports,
    parameter type CompletionT = rapt_pkg::completion_t,
    parameter unsigned MDQ_SIZE = 4,
    parameter unsigned ROB_SIZE = Cfg.rob_entries,
    parameter unsigned PLEN     = rapt_pkg::index_bits(Cfg.phys_regs),
    parameter unsigned RLEN     = rapt_pkg::index_bits(Cfg.arch_regs),
    parameter unsigned XLEN     = Cfg.xlen
) (
    input CompletionT completion[NumCompletions],
    input clock,
    input reset,

    cmu_bcast_if.in cmu_bcast,

    // Dispatch source + arbitration (same handshake shape as the RS)
    input SlotT dispatch[NumSlots],
    dpu_iq_if.rs  disp,

    // CDB forwarding sources (other value-producing pipes)

    // Own writeback
    output CompletionT exu_wb_mul
);
  localparam unsigned MDQLen = (MDQ_SIZE > 1) ? $clog2(MDQ_SIZE) : 1;
  localparam unsigned GenBits = $bits(dispatch[0].generation);

  // === IQ state ===
  logic [MDQ_SIZE-1:0] mdq_valid;
  logic [MDQ_SIZE-1:0] mdq_issued;
  logic [MDQ_SIZE-1:0] mdq_pr1_busy;
  logic [MDQ_SIZE-1:0] mdq_pr2_busy;
  logic [    XLEN-1:0] mdq_vj      [MDQ_SIZE];
  logic [    XLEN-1:0] mdq_vk      [MDQ_SIZE];
  logic [    PLEN-1:0] mdq_pr1     [MDQ_SIZE];
  logic [    PLEN-1:0] mdq_pr2     [MDQ_SIZE];
  logic [    PLEN-1:0] mdq_prd     [MDQ_SIZE];
  logic [    RLEN-1:0] mdq_rd      [MDQ_SIZE];
  logic [$clog2(ROB_SIZE)-1:0] mdq_dest[MDQ_SIZE];
  logic [GenBits-1:0] mdq_generation[MDQ_SIZE];
  logic [    XLEN-1:0] mdq_pc      [MDQ_SIZE];
  logic [MDQ_SIZE-1:0] mdq_c;
  logic [MDQ_SIZE-1:0] mdq_word;
  logic [         4:0] mdq_alu     [MDQ_SIZE];
  logic [    XLEN-1:0] mdq_pnpc    [MDQ_SIZE];

  // === Unified CDB view for operand wakeup ===
  // All sources use one typed completion array.
  localparam int unsigned NWB = NumCompletions;
  logic            wb_valid [NWB];
  logic [PLEN-1:0] wb_prd   [NWB];
  logic [XLEN-1:0] wb_result[NWB];
  for (genvar p = 0; p < NWB; p++) begin : g_completion_view
    assign wb_valid[p] = completion[p].valid;
    assign wb_prd[p] = completion[p].prd;
    assign wb_result[p] = completion[p].result;
  end

  function automatic logic wb_hit(input logic [PLEN-1:0] pr);
    wb_hit = 1'b0;
    for (int p = 0; p < NWB; p++) begin
      wb_hit |= (pr != '0) && wb_valid[p] && (wb_prd[p] == pr);
    end
  endfunction

  function automatic logic [XLEN-1:0] wb_val(input logic [PLEN-1:0] pr,
                                             input logic [XLEN-1:0] dflt);
    wb_val = dflt;
    for (int p = NWB - 1; p >= 0; p--) begin
      if ((pr != '0) && wb_valid[p] && (wb_prd[p] == pr)) wb_val = wb_result[p];
    end
  endfunction

  // Same-cycle enqueue snoop (entry invisible to the loop until next cycle)
  function automatic logic [PLEN-1:0] wake_pr(input logic [PLEN-1:0] pr);
    return wb_hit(pr) ? '0 : pr;
  endfunction

  function automatic logic [XLEN-1:0] wake_val(input logic [PLEN-1:0] pr,
                                               input logic [XLEN-1:0] dflt);
    return wb_val(pr, dflt);
  endfunction

  // Per-entry resident forwarding
  logic [MDQ_SIZE-1:0] mdq_fwd1_hit;
  logic [MDQ_SIZE-1:0] mdq_fwd2_hit;
  logic [XLEN-1:0] mdq_fwd1_val[MDQ_SIZE];
  logic [XLEN-1:0] mdq_fwd2_val[MDQ_SIZE];
  always_comb begin
    for (int i = 0; i < MDQ_SIZE; i++) begin
      mdq_fwd1_hit[i] = mdq_pr1_busy[i] && wb_hit(mdq_pr1[i]);
      mdq_fwd2_hit[i] = mdq_pr2_busy[i] && wb_hit(mdq_pr2[i]);
      mdq_fwd1_val[i] = wb_val(mdq_pr1[i], mdq_vj[i]);
      mdq_fwd2_val[i] = wb_val(mdq_pr2[i], mdq_vk[i]);
    end
  end

  int alloc_slot[MDQ_SIZE];
  always_comb begin
    automatic logic [MDQ_SIZE-1:0] remaining;
    remaining = ~mdq_valid;
    for (int s = 0; s < NumSlots; s++) begin
      disp.free_found[s] = 1'b0;
      disp.free_idx[s] = '0;
      for (int e = 0; e < MDQ_SIZE; e++)
      if (!disp.free_found[s] && remaining[e]) begin
        disp.free_found[s] = 1'b1;
        disp.free_idx[s] = MDQLen'(e);
        remaining[e] = 1'b0;
      end
    end
  end
  for (genvar s = 0; s < NumSlots; s++) begin : g_alloc_contract
    `RAPT_SVA_IMPLY(clock, reset || cmu_bcast.flush_pipe, QUEUE_ALLOC_FREE, disp.accept[s],
                    !mdq_valid[disp.rs_idx[s]])
    for (genvar t = s + 1; t < NumSlots; t++) begin : g_unique
      `RAPT_SVA_IMPLY(clock, reset || cmu_bcast.flush_pipe, QUEUE_ALLOC_UNIQUE,
                      disp.accept[s] && disp.accept[t], disp.rs_idx[s] != disp.rs_idx[t])
    end
  end
  always_comb begin
    for (int e = 0; e < MDQ_SIZE; e++) begin
      alloc_slot[e] = -1;
      for (int s = 0; s < NumSlots; s++)
      if (disp.accept[s] && int'(disp.rs_idx[s]) == e) alloc_slot[e] = s;
    end
  end
  // === Age matrix (same strict-partial-order pattern as the RS) ===
  logic [MDQ_SIZE-1:0] age_mat[MDQ_SIZE];
  logic [MDQ_SIZE-1:0] age_col[MDQ_SIZE];
  always_comb begin
    for (int j = 0; j < MDQ_SIZE; j++) begin
      for (int i = 0; i < MDQ_SIZE; i++) begin
        age_col[j][i] = (i == j) ? 1'b0 : age_mat[i][j];
      end
    end
  end

  function automatic logic [MDQ_SIZE-1:0] age_oldest_oh(input logic [MDQ_SIZE-1:0] vec);
    logic [MDQ_SIZE-1:0] oh;
    for (int i = 0; i < MDQ_SIZE; i++) oh[i] = vec[i] && ((age_col[i] & vec) == '0);
    return oh;
  endfunction

  function automatic logic [MDQLen-1:0] oh2bin(input logic [MDQ_SIZE-1:0] oh);
    logic [MDQLen-1:0] bin;
    bin = '0;
    for (int i = 0; i < MDQ_SIZE; i++) begin
      if (oh[i]) bin = bin | i[MDQLen-1:0];
    end
    return bin;
  endfunction

  // === Issue selection: oldest ready, not yet issued ===
  logic [MDQ_SIZE-1:0] mdq_elig_vec;
  always_comb begin
    for (int i = 0; i < MDQ_SIZE; i++) begin
      mdq_elig_vec[i] = mdq_valid[i] && !mdq_issued[i] && !mdq_pr1_busy[i] && !mdq_pr2_busy[i];
    end
  end

  logic [MDQ_SIZE-1:0] sel_onehot;
  logic sel_found;
  logic [MDQLen-1:0] sel_idx;
  assign sel_onehot = age_oldest_oh(mdq_elig_vec);
  assign sel_found  = |sel_onehot;
  assign sel_idx    = oh2bin(sel_onehot);

  // === MUL/DIV function unit ===
  logic [XLEN-1:0] fu_out_r;
  logic [MDQLen-1:0] fu_out_tag;
  logic fu_out_valid;
  logic fu_in_ready;

`ifdef RAPT_M_EXTENSION
  rapt_ieu_mul #(
      .TAG_W(MDQLen)
  ) mul (
      .clock(clock),
      .reset(reset),
      .flush(cmu_bcast.flush_pipe),
      .in_a(mdq_vj[sel_idx]),
      .in_b(mdq_vk[sel_idx]),
      .in_op(mdq_alu[sel_idx]),
      .in_word(mdq_word[sel_idx]),
      .in_tag(sel_idx),
      .in_valid(sel_found && fu_in_ready),
      .in_ready(fu_in_ready),
      .out_r(fu_out_r),
      .out_tag(fu_out_tag),
      .out_valid(fu_out_valid)
  );
`else
  assign fu_out_r     = '0;
  assign fu_out_tag   = '0;
  assign fu_out_valid = 1'b0;
  assign fu_in_ready  = 1'b0;
`endif

  // === Writeback (CDB) ===
  // Driven straight from the FU's registered outputs; entry payload is
  // looked up by tag. MUL/DIV never redirects on its own, but a BTB alias
  // may have predicted a bogus target, so mispredict still compares
  // against the carried pnpc.
  logic [XLEN-1:0] wb_npc;
  assign wb_npc = mdq_pc[fu_out_tag] + (mdq_c[fu_out_tag] ? 'h2 : 'h4);

  assign exu_wb_mul.valid = fu_out_valid;
  assign exu_wb_mul.dest = mdq_dest[fu_out_tag];
  assign exu_wb_mul.generation = mdq_generation[fu_out_tag];
  assign exu_wb_mul.result = fu_out_r;
  assign exu_wb_mul.prd = mdq_prd[fu_out_tag];
  assign exu_wb_mul.rd = mdq_rd[fu_out_tag];
  assign exu_wb_mul.pc = mdq_pc[fu_out_tag];
  assign exu_wb_mul.npc = wb_npc;
  assign exu_wb_mul.btaken = 1'b0;
  assign exu_wb_mul.mispredict = (wb_npc != mdq_pnpc[fu_out_tag]);
  // Pure arithmetic pipe: no CSR / trap / MEM sideband (tie-offs).
  assign exu_wb_mul.csr_wen = 1'b0;
  assign exu_wb_mul.csr_wdata = '0;
  assign exu_wb_mul.fp_flags_valid = 1'b0;
  assign exu_wb_mul.fp_flags = '0;
  assign exu_wb_mul.trap = 1'b0;
  assign exu_wb_mul.tval = '0;
  assign exu_wb_mul.cause = '0;
  assign exu_wb_mul.wen = 1'b0;
  assign exu_wb_mul.alu = '0;
  assign exu_wb_mul.sq_waddr = '0;
  assign exu_wb_mul.sq_wdata = '0;
  assign exu_wb_mul.sq_wdata64 = '0;
  assign exu_wb_mul.sq_fp64 = 1'b0;
  assign exu_wb_mul.difftest_skip = 1'b0;

  // === Sequential: alloc / wakeup / issue / completion ===
  always_ff @(posedge clock) begin
    if (reset || cmu_bcast.flush_pipe) begin
      mdq_valid    <= '0;
      mdq_issued   <= '0;
      mdq_pr1_busy <= '0;
      mdq_pr2_busy <= '0;
      // Payload arrays (vj/vk/pc/alu/pnpc/...), pr1/pr2, and the age
      // matrix are intentionally NOT reset: every read is gated by
      // mdq_valid[]/busy bits (FU input is qualified by sel_found, the
      // wakeup snoop lives inside `if (mdq_valid[i])`), and allocation
      // initializes each new entry's age row/column before its valid bit
      // is set (same argument as rapt_iq).  Only valid/issued/busy
      // control bits stay on the reset network.
    end else begin
      for (int e = 0; e < MDQ_SIZE; e++)
      if (alloc_slot[e] >= 0) begin
        mdq_valid[e]    <= 1'b1;
        mdq_issued[e]   <= 1'b0;
        mdq_vj[e]       <= wake_val(dispatch[alloc_slot[e]].pr1, dispatch[alloc_slot[e]].op1);
        mdq_vk[e]       <= wake_val(dispatch[alloc_slot[e]].pr2, dispatch[alloc_slot[e]].op2);
        mdq_pr1[e]      <= wake_pr(dispatch[alloc_slot[e]].pr1);
        mdq_pr2[e]      <= wake_pr(dispatch[alloc_slot[e]].pr2);
        mdq_pr1_busy[e] <= |wake_pr(dispatch[alloc_slot[e]].pr1);
        mdq_pr2_busy[e] <= |wake_pr(dispatch[alloc_slot[e]].pr2);
        mdq_prd[e]      <= dispatch[alloc_slot[e]].prd;
        mdq_rd[e]       <= dispatch[alloc_slot[e]].uop.rd;
        mdq_dest[e]     <= dispatch[alloc_slot[e]].dest;
        mdq_generation[e] <= dispatch[alloc_slot[e]].generation;
        mdq_pc[e]       <= dispatch[alloc_slot[e]].uop.pc;
        mdq_c[e]        <= dispatch[alloc_slot[e]].uop.c;
        mdq_word[e]     <= dispatch[alloc_slot[e]].uop.execute.int_op.word;
        mdq_alu[e]      <= dispatch[alloc_slot[e]].uop.execute.int_op.alu[4:0];
        mdq_pnpc[e]     <= dispatch[alloc_slot[e]].uop.pnpc;
      end
      // ---- Resident operand wakeup (skip slots being allocated) ----
      for (int i = 0; i < MDQ_SIZE; i++) begin
        if (mdq_valid[i]) begin
          if (mdq_fwd1_hit[i]) begin
            mdq_vj[i]       <= mdq_fwd1_val[i];
            mdq_pr1[i]      <= '0;
            mdq_pr1_busy[i] <= 1'b0;
          end
          if (mdq_fwd2_hit[i]) begin
            mdq_vk[i]       <= mdq_fwd2_val[i];
            mdq_pr2[i]      <= '0;
            mdq_pr2_busy[i] <= 1'b0;
          end
        end
      end

      // ---- FU issue bookkeeping ----
      if (sel_found && fu_in_ready) begin
        mdq_issued[sel_idx] <= 1'b1;
      end

      // ---- Completion: free the entry on tag return ----
      if (fu_out_valid) begin
        mdq_valid[fu_out_tag]  <= 1'b0;
        mdq_issued[fu_out_tag] <= 1'b0;
      end

      // New entries are younger than residents and ordered by dispatch slot.
      for (int i = 0; i < MDQ_SIZE; i++) begin
        for (int j = 0; j < MDQ_SIZE; j++) begin
          if (alloc_slot[i] >= 0 && alloc_slot[j] >= 0)
            age_mat[i][j] <= alloc_slot[i] < alloc_slot[j];
          else if (alloc_slot[i] >= 0) age_mat[i][j] <= 1'b0;
          else if (alloc_slot[j] >= 0) age_mat[i][j] <= mdq_valid[i];
        end
      end

    end
  end

  // ==========================================================================
  //  Assertions (enable with +define+RAPT_ASSERT_EN)
  // ==========================================================================

  // ONE_HOT: issue select must be one-hot (age matrix strict partial order).
  `RAPT_SVA_IMPLY(clock, reset, MDQ_SEL_ONEHOT, sel_found, $onehot(sel_onehot))

  // HANDSHAKE: a completing tag must reference a valid, issued entry.
  `RAPT_SVA_IMPLY(clock, reset, MDQ_WB_VALID_ENTRY, fu_out_valid,
                  (mdq_valid[fu_out_tag] && mdq_issued[fu_out_tag]))

  assign exu_wb_mul.updates = '{control_flow: 1'b1, default: '0};
endmodule

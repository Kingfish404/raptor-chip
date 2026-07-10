`include "rapt.svh"
`include "rapt_if.svh"

// MUL/DIV pipeline (4th execution pipe): private issue queue + MUL/DIV FU
// + dedicated CDB writeback port.
//
// Phase 1 of the execution-engine decoupling: carve the multiplier out of
// the unified RS so MUL/DIV uops no longer occupy RS entries for their
// whole latency nor consume an ALU-A issue slot at completion.
//
// Responsibilities:
//   * Buffer dispatched MUL/DIV uops with operands (small age-ordered IQ)
//   * Wake operands from the slow CDB ports (ALU-A / ALU-B / MEM / self).
//     No fast load-use path here: a load-fed MUL wakes one cycle later on
//     the confirming MEM broadcast, trading a cycle of mul latency for a
//     narrow wakeup network.
//   * Feed the tag-based rapt_exu_mul FU (pipelined MUL, iterative DIV)
//   * Drive the `exu_wb_mul` CDB port straight from the FU's registered
//     outputs (dest/prd/rd looked up by tag)
//
// A uop is routed here only if it is pure MUL/DIV arithmetic
// (see `a_is_mdq` in rapt_exu): never memory / system / trap / branch,
// so this pipe carries no CSR, trap, or store sideband (tied 0).
module rapt_exu_muldiv #(
    parameter unsigned MDQ_SIZE = 4,
    parameter unsigned ROB_SIZE = `RAPT_ROB_SIZE,
    parameter unsigned PLEN     = `RAPT_PHY_LEN,
    parameter unsigned RLEN     = `RAPT_REG_LEN,
    parameter unsigned XLEN     = `RAPT_XLEN
) (
    input clock,
    input reset,

    cmu_bcast_if.in cmu_bcast,

    // Dispatch source + arbitration (same handshake shape as the RS)
    rou_exu_if.monitor rou_exu,
    exu_disp_rs_if.rs  disp,

    // CDB forwarding sources (other value-producing pipes)
    exu_wb_if.in exu_rou,
    exu_wb_if.in exu_rou_b,
    exu_wb_if.in exu_ioq_bcast,

    // Own writeback
    exu_wb_if.out exu_wb_mul
);
  localparam unsigned MDQLen = (MDQ_SIZE > 1) ? $clog2(MDQ_SIZE) : 1;

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
  logic [    XLEN-1:0] mdq_pc      [MDQ_SIZE];
  logic [MDQ_SIZE-1:0] mdq_c;
  logic [MDQ_SIZE-1:0] mdq_word;
  logic [         4:0] mdq_alu     [MDQ_SIZE];
  logic [    XLEN-1:0] mdq_pnpc    [MDQ_SIZE];

  // === Unified CDB view for operand wakeup ===
  // [0]=MEM [1]=ALU-A [2]=ALU-B [3]=self. Rename guarantees a unique
  // producer per physical register, so port order is don't-care.
  localparam int unsigned NWB = 4;
  logic            wb_valid [NWB];
  logic [PLEN-1:0] wb_prd   [NWB];
  logic [XLEN-1:0] wb_result[NWB];
  assign wb_valid[0]  = exu_ioq_bcast.valid;
  assign wb_prd[0]    = exu_ioq_bcast.prd;
  assign wb_result[0] = exu_ioq_bcast.result;
  assign wb_valid[1]  = exu_rou.valid;
  assign wb_prd[1]    = exu_rou.prd;
  assign wb_result[1] = exu_rou.result;
  assign wb_valid[2]  = exu_rou_b.valid;
  assign wb_prd[2]    = exu_rou_b.prd;
  assign wb_result[2] = exu_rou_b.result;
  assign wb_valid[3]  = exu_wb_mul.valid;
  assign wb_prd[3]    = exu_wb_mul.prd;
  assign wb_result[3] = exu_wb_mul.result;

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

  // === Free-slot PEs (exposed via disp) ===
  logic [MDQ_SIZE-1:0] mdq_free_vec;
  assign mdq_free_vec = ~mdq_valid;

  logic [MDQLen-1:0] free_idx_a, free_idx_b;
  logic free_found_a, free_found_b;
  always_comb begin
    free_idx_a   = '0;
    free_found_a = 1'b0;
    for (int i = 0; i < MDQ_SIZE; i++) begin
      if (!free_found_a && mdq_free_vec[i]) begin
        free_idx_a   = i[MDQLen-1:0];
        free_found_a = 1'b1;
      end
    end
  end
`ifdef RAPT_DUAL_ISSUE
  always_comb begin
    free_idx_b   = '0;
    free_found_b = 1'b0;
    for (int i = 0; i < MDQ_SIZE; i++) begin
      if (!free_found_b && mdq_free_vec[i]
          && !(free_found_a && i[MDQLen-1:0] == free_idx_a)) begin
        free_idx_b   = i[MDQLen-1:0];
        free_found_b = 1'b1;
      end
    end
  end
`else
  assign free_idx_b   = '0;
  assign free_found_b = 1'b0;
`endif

  assign disp.free_found_a = free_found_a;
  assign disp.free_found_b = free_found_b;
  assign disp.free_idx_a   = free_idx_a;
  assign disp.free_idx_b   = free_idx_b;

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
      mdq_elig_vec[i] = mdq_valid[i] && !mdq_issued[i]
                        && !mdq_pr1_busy[i] && !mdq_pr2_busy[i];
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
  rapt_exu_mul #(
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
  assign exu_wb_mul.trap = 1'b0;
  assign exu_wb_mul.tval = '0;
  assign exu_wb_mul.cause = '0;
  assign exu_wb_mul.wen = 1'b0;
  assign exu_wb_mul.alu = '0;
  assign exu_wb_mul.sq_waddr = '0;
  assign exu_wb_mul.sq_wdata = '0;
  assign exu_wb_mul.difftest_skip = 1'b0;

  // === Sequential: alloc / wakeup / issue / completion ===
  always_ff @(posedge clock) begin
    if (reset || cmu_bcast.flush_pipe) begin
      mdq_valid    <= '0;
      mdq_issued   <= '0;
      mdq_pr1_busy <= '0;
      mdq_pr2_busy <= '0;
      mdq_c        <= '0;
      mdq_word     <= '0;
      for (int i = 0; i < MDQ_SIZE; i++) begin
        age_mat[i]  <= '0;
        mdq_vj[i]   <= '0;
        mdq_vk[i]   <= '0;
        mdq_pr1[i]  <= '0;
        mdq_pr2[i]  <= '0;
        mdq_prd[i]  <= '0;
        mdq_rd[i]   <= '0;
        mdq_dest[i] <= '0;
        mdq_pc[i]   <= '0;
        mdq_alu[i]  <= '0;
        mdq_pnpc[i] <= '0;
      end
    end else begin
      // ---- Allocation (slot A / slot B write distinct free slots) ----
      if (disp.accept_a) begin
        mdq_valid[free_idx_a]    <= 1'b1;
        mdq_issued[free_idx_a]   <= 1'b0;
        mdq_vj[free_idx_a]       <= wake_val(rou_exu.pr1, rou_exu.op1);
        mdq_vk[free_idx_a]       <= wake_val(rou_exu.pr2, rou_exu.op2);
        mdq_pr1[free_idx_a]      <= wake_pr(rou_exu.pr1);
        mdq_pr2[free_idx_a]      <= wake_pr(rou_exu.pr2);
        mdq_pr1_busy[free_idx_a] <= |wake_pr(rou_exu.pr1);
        mdq_pr2_busy[free_idx_a] <= |wake_pr(rou_exu.pr2);
        mdq_prd[free_idx_a]      <= rou_exu.prd;
        mdq_rd[free_idx_a]       <= rou_exu.uop.rd;
        mdq_dest[free_idx_a]     <= rou_exu.dest;
        mdq_pc[free_idx_a]       <= rou_exu.uop.pc;
        mdq_c[free_idx_a]        <= rou_exu.uop.c;
        mdq_word[free_idx_a]     <= rou_exu.uop.word;
        mdq_alu[free_idx_a]      <= rou_exu.uop.alu[4:0];
        mdq_pnpc[free_idx_a]     <= rou_exu.uop.pnpc;
      end
`ifdef RAPT_DUAL_ISSUE
      if (disp.accept_b) begin
        mdq_valid[disp.b_rs_idx]    <= 1'b1;
        mdq_issued[disp.b_rs_idx]   <= 1'b0;
        mdq_vj[disp.b_rs_idx]       <= wake_val(rou_exu.pr1_b, rou_exu.op1_b);
        mdq_vk[disp.b_rs_idx]       <= wake_val(rou_exu.pr2_b, rou_exu.op2_b);
        mdq_pr1[disp.b_rs_idx]      <= wake_pr(rou_exu.pr1_b);
        mdq_pr2[disp.b_rs_idx]      <= wake_pr(rou_exu.pr2_b);
        mdq_pr1_busy[disp.b_rs_idx] <= |wake_pr(rou_exu.pr1_b);
        mdq_pr2_busy[disp.b_rs_idx] <= |wake_pr(rou_exu.pr2_b);
        mdq_prd[disp.b_rs_idx]      <= rou_exu.prd_b;
        mdq_rd[disp.b_rs_idx]       <= rou_exu.uop_b.rd;
        mdq_dest[disp.b_rs_idx]     <= rou_exu.dest_b;
        mdq_pc[disp.b_rs_idx]       <= rou_exu.uop_b.pc;
        mdq_c[disp.b_rs_idx]        <= rou_exu.uop_b.c;
        mdq_word[disp.b_rs_idx]     <= rou_exu.uop_b.word;
        mdq_alu[disp.b_rs_idx]      <= rou_exu.uop_b.alu[4:0];
        mdq_pnpc[disp.b_rs_idx]     <= rou_exu.uop_b.pnpc;
      end
`endif

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

      // ---- Age matrix updates on allocation (same pattern as the RS) ----
`ifdef RAPT_DUAL_ISSUE
      for (int i = 0; i < MDQ_SIZE; i++) begin
        for (int j = 0; j < MDQ_SIZE; j++) begin
          if (disp.accept_a && disp.accept_b
              && i == int'(free_idx_a) && j == int'(disp.b_rs_idx)) begin
            age_mat[i][j] <= 1'b1;
          end else if (disp.accept_b && i == int'(disp.b_rs_idx)) begin
            age_mat[i][j] <= 1'b0;
          end else if (disp.accept_b && j == int'(disp.b_rs_idx)
                     && i != int'(disp.b_rs_idx)) begin
            age_mat[i][j] <= mdq_valid[i];
          end else if (disp.accept_a && i == int'(free_idx_a)) begin
            age_mat[i][j] <= 1'b0;
          end else if (disp.accept_a && j == int'(free_idx_a)
                     && i != int'(free_idx_a)) begin
            age_mat[i][j] <= mdq_valid[i];
          end
        end
      end
`else
      if (disp.accept_a) begin
        for (int j = 0; j < MDQ_SIZE; j++) begin
          age_mat[free_idx_a][j] <= 1'b0;
          if (j != int'(free_idx_a)) age_mat[j][free_idx_a] <= mdq_valid[j];
        end
      end
`endif
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

endmodule

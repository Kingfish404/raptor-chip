`include "rapt.svh"
`include "rapt_if.svh"

// Reservation Station (RS): out-of-order issue queue for ALU/branch/CSR/MUL ops.
//
// Responsibilities:
//   * Hold dispatched non-memory uops with their operands and control bits
//   * Forward operands from in-flight writeback buses (exu_rou / exu_rou_b /
//     exu_ioq_bcast)
//   * Schedule (age-matrix) the oldest ready entry to each issue port:
//       - port A: full ALU + CSR / system / trap / MUL writeback
//       - port B: simple ALU + jen (JAL/JALR link write)
//       - port C: dedicated BRU for conditional branches (ben)
//       - MUL FU: pipelined multiplier + iterative divider, tag-based
//   * Drive `exu_rou` / `exu_rou_b` / `exu_rou_c` writebacks
//
// The MUL FU and three ALU instances are encapsulated here because they are
// trivially driven by RS state and have no useful standalone reuse.
module rapt_exu_rs #(
    parameter unsigned RS_SIZE  = `RAPT_RS_SIZE,
    parameter unsigned ROB_SIZE = `RAPT_ROB_SIZE,
    parameter unsigned PLEN     = `RAPT_PHY_LEN,
    parameter unsigned RLEN     = `RAPT_REG_LEN,
    parameter unsigned XLEN     = `RAPT_XLEN
) (
    input clock,
    input reset,

    cmu_bcast_if.in cmu_bcast,
    csr_bcast_if.in csr_bcast,

    // Dispatch source + arbitration
    rou_exu_if.monitor rou_exu,
    exu_disp_rs_if.rs  disp,

    // Forwarding source
    exu_ioq_bcast_if.in exu_ioq_bcast,

    // CSR access
    exu_csr_if.master exu_csr,

    // Writebacks (ROB)
    exu_rou_if.out   exu_rou,
    exu_rou_b_if.out exu_rou_b,
    exu_rou_c_if.out exu_rou_c,

    // Dispatch-only uop payload snapshot (indexed by ROB destination).
    // Read at issue time by slot A to source `ecall/ebreak/mret/sret/csr_*/inst`.
    input rapt_pkg::uop_payload_t uop_pl [ROB_SIZE]
);
  localparam unsigned ROBLen = $clog2(ROB_SIZE);
  localparam unsigned RSLen = $clog2(RS_SIZE);

  // === RS state ===
  logic [RS_SIZE-1:0] rs_valid;
  logic [   XLEN-1:0] rs_pc         [RS_SIZE];
  logic               rs_c          [RS_SIZE];
  logic               rs_word       [RS_SIZE];
  logic [        5:0] rs_alu        [RS_SIZE];
  logic [   XLEN-1:0] rs_vj         [RS_SIZE];
  logic [   XLEN-1:0] rs_vk         [RS_SIZE];
  logic [ ROBLen-1:0] rs_dest       [RS_SIZE];

  logic [   PLEN-1:0] rs_pr1        [RS_SIZE];
  logic [   PLEN-1:0] rs_pr2        [RS_SIZE];
  // Per-entry operand busy flags. Latched at dispatch from `|pr1` / `|pr2`
  // and cleared on CDB match. Collapses the former 6-bit `rs_pr*[i] == 0`
  // zero-check into a single bit read in every eligibility vector, shaving
  // gate levels from the wakeup -> select cone.
  logic [RS_SIZE-1:0] rs_pr1_busy;
  logic [RS_SIZE-1:0] rs_pr2_busy;
  logic [   PLEN-1:0] rs_prd        [RS_SIZE];
  logic [   RLEN-1:0] rs_rd         [RS_SIZE];

  logic [RS_SIZE-1:0] rs_mul_ready;
  logic [RS_SIZE-1:0] rs_mul_issued;
  logic [   XLEN-1:0] rs_mul_a      [RS_SIZE];

  logic [RS_SIZE-1:0] rs_jen;
  logic [RS_SIZE-1:0] rs_br_jmp;
  logic [RS_SIZE-1:0] rs_br_cond;
  logic [RS_SIZE-1:0] rs_jump;
  logic [   XLEN-1:0] rs_imm        [RS_SIZE];

  // Consolidated slot-B ineligibility flag, latched at dispatch. Collapses
  // the previous `rs_system|rs_trap|rs_ecall|rs_ebreak|rs_mret|rs_sret|
  // (rs_csr_csw != 0)` disjunction into one bit per entry to keep the
  // eligibility cone short after moving the underlying fields to `uop_pl`.
  logic [RS_SIZE-1:0] rs_b_block;

  logic               rs_trap       [RS_SIZE];
  logic [   XLEN-1:0] rs_tval       [RS_SIZE];
  logic [   XLEN-1:0] rs_cause      [RS_SIZE];

  // Per-slot aliases into the dispatch-only payload snapshot. `rs_dest`
  // maps each RS entry to its ROB destination; dereference gives the
  // original uop fields without duplicating them in RS. Only slot A
  // currently needs a view (system / ecall / mret / sret / csr_* live in
  // payload); slots B/C never carry those control bits.
  rapt_pkg::uop_payload_t rs_pl_a;

  // === Selection ===
  logic [  RSLen-1:0] valid_idx_a;
  logic [  RSLen-1:0] valid_idx_b;
  logic [  RSLen-1:0] valid_idx_c;
  logic [  RSLen-1:0] mul_rs_idx;
  logic valid_found_a, valid_found_b, valid_found_c, mul_found;

  assign rs_pl_a = uop_pl[rs_dest[valid_idx_a]];

  logic [RSLen-1:0] free_idx_a;
  logic             free_found_a;
  logic [RSLen-1:0] free_idx_b;
  logic             free_found_b;

  logic [RS_SIZE-1:0] rs_free_vec, rs_ready_vec, rs_mul_vec, rs_simple_b_vec, rs_bru_vec;

  // === Age matrix ===
  // age_mat[i][j] = 1 iff RS entry i is older than j. Diagonal = 0.
  logic [RS_SIZE-1:0] age_mat[RS_SIZE];
  logic [RS_SIZE-1:0] age_col[RS_SIZE];
  logic [RS_SIZE-1:0] sel_b_msk;
  logic [RS_SIZE-1:0] sel_a_onehot;

  // === Eligibility vectors ===
  logic [RS_SIZE-1:0] rs_pr_ready;
  always_comb begin
    for (int i = 0; i < RS_SIZE; i++) begin
      rs_pr_ready[i] = ~(rs_pr1_busy[i] | rs_pr2_busy[i]);
      rs_free_vec[i] = !rs_valid[i];
      // Slot A: everything except conditional branches (port C handles ben).
      rs_ready_vec[i] = rs_valid[i] && rs_pr_ready[i]
                       && (rs_alu[i][5:4] != 2'b01 || rs_mul_ready[i])
                       && !rs_br_cond[i];
      // MUL FU eligibility: ready operands, not yet issued/completed.
      rs_mul_vec[i]   = rs_valid[i] && rs_alu[i][5:4] == 2'b01
                       && rs_pr_ready[i]
                       && !rs_mul_issued[i] && !rs_mul_ready[i];
      // Slot B: simple arithmetic + jen (no CSR/system/trap/mul/ben).
      rs_simple_b_vec[i] = rs_valid[i] && rs_pr_ready[i]
                       && rs_alu[i][5:4] != 2'b01
                       && !rs_trap[i]
                       && !rs_br_cond[i]
                       && !rs_b_block[i];
      // Port C (BRU): conditional branches only.
      rs_bru_vec[i] = rs_valid[i] && rs_pr_ready[i] && rs_br_cond[i];
    end
  end

  // === Free-vector PEs (exposed via disp.rs) ===
  always_comb begin
    free_idx_a   = '0;
    free_found_a = 1'b0;
    for (int i = 0; i < RS_SIZE; i++) begin
      if (!free_found_a && rs_free_vec[i]) begin
        free_idx_a   = i[$clog2(RS_SIZE)-1:0];
        free_found_a = 1'b1;
      end
    end
  end
`ifdef RAPT_DUAL_ISSUE
  always_comb begin
    free_idx_b   = '0;
    free_found_b = 1'b0;
    for (int i = 0; i < RS_SIZE; i++) begin
      if (!free_found_b && rs_free_vec[i] && !(free_found_a && i[$clog2(
              RS_SIZE
          )-1:0] == free_idx_a)) begin
        free_idx_b   = i[$clog2(RS_SIZE)-1:0];
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
  assign disp.mul_found    = mul_found;

  // === Age-matrix transpose for column lookups ===
  // `age_col[i]` = set of entries strictly older than i. A ready entry is
  // the oldest of a subset S iff no older entry is also in S, i.e.
  // `(age_col[i] & S) == 0`.
  always_comb begin
    for (int j = 0; j < RS_SIZE; j++) begin
      for (int i = 0; i < RS_SIZE; i++) begin
        age_col[j][i] = age_mat[i][j];
      end
    end
  end

  // -------------------------------------------------------------------
  // Age-based select helpers
  //
  // `age_oldest_oh(vec)` returns the one-hot pick of the oldest entry in
  // `vec`. Each bit is computed in parallel (3-level tree on top of 8-bit
  // AND + zero-check). Safe because the age matrix is a strict partial
  // order, so at most one element of any non-empty subset satisfies the
  // `no older member present` predicate.
  //
  // `oh2bin(oh)` collapses a one-hot into its binary index with a
  // $clog2-stage OR tree (each output bit ORs the one-hot positions whose
  // index has that bit set).
  //
  // Used for MUL / slot-B / port-C picks where the consumer sees the idx
  // but not a wide data mux. Slot A uses a different form (see below)
  // because its idx feeds RS-wide data muxes (`rs_vj[idx]` etc.) -- a
  // linear priority encoder there lets the synthesizer fold early-out
  // comparisons into the mux select cones, which empirically gives
  // better PPA than the onehot form.
  // -------------------------------------------------------------------
  function automatic logic [RS_SIZE-1:0] age_oldest_oh(input logic [RS_SIZE-1:0] vec);
    logic [RS_SIZE-1:0] oh;
    for (int i = 0; i < RS_SIZE; i++) oh[i] = vec[i] && ((age_col[i] & vec) == '0);
    return oh;
  endfunction

  function automatic logic [RSLen-1:0] oh2bin(input logic [RS_SIZE-1:0] oh);
    logic [RSLen-1:0] bin;
    bin = '0;
    for (int i = 0; i < RS_SIZE; i++) begin
      if (oh[i]) bin = bin | i[RSLen-1:0];
    end
    return bin;
  endfunction

  // ---- Slot A: oldest ready entry (linear PE for crit-path PPA) ----
  always_comb begin
    valid_idx_a   = '0;
    valid_found_a = 1'b0;
    sel_a_onehot  = '0;
    for (int i = 0; i < RS_SIZE; i++) begin
      if (!valid_found_a && rs_ready_vec[i] && ((age_col[i] & rs_ready_vec) == '0)) begin
        valid_idx_a   = i[RSLen-1:0];
        valid_found_a = 1'b1;
      end
    end
    if (valid_found_a) sel_a_onehot[valid_idx_a] = 1'b1;
  end

  // ---- MUL FU pick ----
  logic [RS_SIZE-1:0] sel_mul_onehot;
  assign sel_mul_onehot = age_oldest_oh(rs_mul_vec);
  assign mul_found      = |sel_mul_onehot;
  assign mul_rs_idx     = oh2bin(sel_mul_onehot);

  // ---- Slot B: oldest simple-ALU entry distinct from slot A ----
  logic [RS_SIZE-1:0] sel_b_onehot;
  assign sel_b_msk     = rs_simple_b_vec & ~sel_a_onehot;
  assign sel_b_onehot  = age_oldest_oh(sel_b_msk);
  assign valid_found_b = |sel_b_onehot;
  assign valid_idx_b   = oh2bin(sel_b_onehot);

  // ---- Port C (BRU): oldest ready conditional branch ----
  logic [RS_SIZE-1:0] sel_c_onehot;
  assign sel_c_onehot  = age_oldest_oh(rs_bru_vec);
  assign valid_found_c = |sel_c_onehot;
  assign valid_idx_c   = oh2bin(sel_c_onehot);

  // === ALU & MUL function units ===
  logic [           XLEN-1:0] alu_result_a;
  logic [           XLEN-1:0] alu_result_b;
  logic [           XLEN-1:0] alu_result_c;
  logic [           XLEN-1:0] reg_wdata_mul;
  logic                       mul_valid;
  logic                       mul_ready;
  logic [$clog2(RS_SIZE)-1:0] mul_out_tag;

  rapt_exu_alu gen_alu_a (
      .s1(rs_vj[valid_idx_a]),
      .s2(rs_vk[valid_idx_a]),
      .op(rs_alu[valid_idx_a]),
      .word(rs_word[valid_idx_a]),
      .out_r(alu_result_a)
  );
  rapt_exu_alu gen_alu_b (
      .s1(rs_vj[valid_idx_b]),
      .s2(rs_vk[valid_idx_b]),
      .op(rs_alu[valid_idx_b]),
      .word(rs_word[valid_idx_b]),
      .out_r(alu_result_b)
  );
  // Port C reuses the full ALU; only branch comparison opcodes ever drive
  // valid_idx_c, so synthesis can prune unreachable cones.
  rapt_exu_alu gen_alu_c (
      .s1(rs_vj[valid_idx_c]),
      .s2(rs_vk[valid_idx_c]),
      .op(rs_alu[valid_idx_c]),
      .word(rs_word[valid_idx_c]),
      .out_r(alu_result_c)
  );

`ifdef RAPT_M_EXTENSION
  rapt_exu_mul #(
      .TAG_W($clog2(RS_SIZE))
  ) mul (
      .clock(clock),
      .reset(reset),
      .flush(cmu_bcast.flush_pipe),
      .in_a(rs_vj[mul_rs_idx]),
      .in_b(rs_vk[mul_rs_idx]),
      .in_op(rs_alu[mul_rs_idx]),
      .in_word(rs_word[mul_rs_idx]),
      .in_tag(mul_rs_idx),
      .in_valid(mul_found && mul_ready),
      .in_ready(mul_ready),
      .out_r(reg_wdata_mul),
      .out_tag(mul_out_tag),
      .out_valid(mul_valid)
  );
`else
  assign reg_wdata_mul = '0;
  assign mul_valid     = 1'b0;
  assign mul_ready     = 1'b0;
  assign mul_out_tag   = '0;
`endif

  // === Sequential: alloc / forward / writeback-clear / MUL completion ===
  always @(posedge clock) begin
    if (reset || cmu_bcast.flush_pipe) begin
      rs_valid      <= '0;
      rs_pr1_busy   <= '0;
      rs_pr2_busy   <= '0;
      rs_mul_ready  <= '0;
      rs_mul_issued <= '0;
      for (int i = 0; i < RS_SIZE; i++) age_mat[i] <= '0;
    end else begin
      // ---- Per-entry state machine ----
      for (bit [XLEN-1:0] i = 0; i < RS_SIZE; i++) begin
        if (free_found_a && i[$clog2(RS_SIZE)-1:0] == free_idx_a) begin
          // Slot-A allocation lands here when accepted by top.
          if (disp.accept_a) begin
            rs_valid[free_idx_a]   <= 1'b1;
            rs_alu[free_idx_a]     <= rou_exu.uop.alu;
            rs_vj[free_idx_a]      <= rou_exu.op1;
            rs_vk[free_idx_a]      <= rou_exu.op2;
            rs_dest[free_idx_a]    <= rou_exu.dest;
            rs_pr1[free_idx_a]     <= rou_exu.pr1;
            rs_pr2[free_idx_a]     <= rou_exu.pr2;
            rs_pr1_busy[free_idx_a] <= |rou_exu.pr1;
            rs_pr2_busy[free_idx_a] <= |rou_exu.pr2;
            rs_prd[free_idx_a]     <= rou_exu.prd;
            rs_rd[free_idx_a]      <= rou_exu.uop.rd;
            rs_c[free_idx_a]       <= rou_exu.uop.c;
            rs_word[free_idx_a]    <= rou_exu.uop.word;
            rs_jen[free_idx_a]     <= rou_exu.uop.jen;
            rs_br_jmp[free_idx_a]  <= (rou_exu.uop.jen || rou_exu.uop.ecall || rou_exu.uop.mret);
            rs_br_cond[free_idx_a] <= (rou_exu.uop.ben);
            rs_jump[free_idx_a]    <= (rou_exu.uop.jen);
            rs_imm[free_idx_a]     <= rou_exu.uop.imm;
            rs_pc[free_idx_a]      <= rou_exu.uop.pc;
            rs_b_block[free_idx_a] <= (rou_exu.uop.system || rou_exu.uop.trap
                                    || rou_exu.uop.ecall  || rou_exu.uop.ebreak
                                    || rou_exu.uop.mret   || rou_exu.uop.sret
                                    || (rou_exu.uop.csr_csw != 0));
            rs_trap[free_idx_a]    <= rou_exu.uop.trap;
            rs_tval[free_idx_a]    <= rou_exu.uop.tval;
            rs_cause[free_idx_a]   <= rou_exu.uop.cause;
          end
        end else if (rs_valid[i] && !rs_pr1_busy[i] && !rs_pr2_busy[i]) begin
          // MUL FU bookkeeping (tag-based completion).
          if (rs_alu[i][5:4] == 2'b01) begin
            if (mul_found && mul_ready && i[$clog2(
                    RS_SIZE
                )-1:0] == mul_rs_idx && !rs_mul_issued[i] && !rs_mul_ready[i]) begin
              rs_mul_issued[i] <= 1'b1;
            end
            if (mul_valid && mul_out_tag == i[$clog2(RS_SIZE)-1:0] && rs_mul_issued[i]) begin
              rs_mul_ready[i]  <= 1'b1;
              rs_mul_issued[i] <= 1'b0;
              rs_mul_a[i]      <= reg_wdata_mul;
            end
          end
          // Writeback clears (slot A / slot B / port C all hit here).
          if ((valid_found_a && valid_idx_a == i[$clog2(
                  RS_SIZE
              )-1:0]) || (valid_found_b && valid_idx_b == i[$clog2(
                  RS_SIZE
              )-1:0]) || (valid_found_c && valid_idx_c == i[$clog2(
                  RS_SIZE
              )-1:0])) begin
            rs_valid[i]      <= 1'b0;
            rs_alu[i]        <= '0;
            rs_mul_ready[i]  <= 1'b0;
            rs_mul_issued[i] <= 1'b0;
          end
        end else if (rs_valid[i]) begin
          // Operand forwarding.
          if (rs_pr1_busy[i] && exu_ioq_bcast.valid && exu_ioq_bcast.prd == rs_pr1[i]) begin
            rs_vj[i]       <= exu_ioq_bcast.result;
            rs_pr1[i]      <= '0;
            rs_pr1_busy[i] <= 1'b0;
          end else if (rs_pr1_busy[i] && exu_rou.valid && exu_rou.prd == rs_pr1[i]) begin
            rs_vj[i]       <= exu_rou.result;
            rs_pr1[i]      <= '0;
            rs_pr1_busy[i] <= 1'b0;
          end else if (rs_pr1_busy[i] && exu_rou_b.valid && exu_rou_b.prd == rs_pr1[i]) begin
            rs_vj[i]       <= exu_rou_b.result;
            rs_pr1[i]      <= '0;
            rs_pr1_busy[i] <= 1'b0;
          end
          if (rs_pr2_busy[i] && exu_ioq_bcast.valid && exu_ioq_bcast.prd == rs_pr2[i]) begin
            rs_vk[i]       <= exu_ioq_bcast.result;
            rs_pr2[i]      <= '0;
            rs_pr2_busy[i] <= 1'b0;
          end else if (rs_pr2_busy[i] && exu_rou.valid && exu_rou.prd == rs_pr2[i]) begin
            rs_vk[i]       <= exu_rou.result;
            rs_pr2[i]      <= '0;
            rs_pr2_busy[i] <= 1'b0;
          end else if (rs_pr2_busy[i] && exu_rou_b.valid && exu_rou_b.prd == rs_pr2[i]) begin
            rs_vk[i]       <= exu_rou_b.result;
            rs_pr2[i]      <= '0;
            rs_pr2_busy[i] <= 1'b0;
          end
        end
      end
`ifdef RAPT_DUAL_ISSUE
      // Slot-B allocation (independent of A). disp.b_rs_idx is the chosen slot.
      if (disp.accept_b) begin
        rs_valid[disp.b_rs_idx] <= 1'b1;
        rs_alu[disp.b_rs_idx] <= rou_exu.uop_b.alu;
        rs_vj[disp.b_rs_idx] <= rou_exu.op1_b;
        rs_vk[disp.b_rs_idx] <= rou_exu.op2_b;
        rs_dest[disp.b_rs_idx] <= rou_exu.dest_b;
        rs_pr1[disp.b_rs_idx] <= rou_exu.pr1_b;
        rs_pr2[disp.b_rs_idx] <= rou_exu.pr2_b;
        rs_pr1_busy[disp.b_rs_idx] <= |rou_exu.pr1_b;
        rs_pr2_busy[disp.b_rs_idx] <= |rou_exu.pr2_b;
        rs_prd[disp.b_rs_idx] <= rou_exu.prd_b;
        rs_rd[disp.b_rs_idx] <= rou_exu.uop_b.rd;
        rs_c[disp.b_rs_idx] <= rou_exu.uop_b.c;
        rs_word[disp.b_rs_idx] <= rou_exu.uop_b.word;
        rs_jen[disp.b_rs_idx] <= rou_exu.uop_b.jen;
        rs_br_jmp[disp.b_rs_idx]  <= (rou_exu.uop_b.jen || rou_exu.uop_b.ecall || rou_exu.uop_b.mret);
        rs_br_cond[disp.b_rs_idx] <= (rou_exu.uop_b.ben);
        rs_jump[disp.b_rs_idx] <= (rou_exu.uop_b.jen);
        rs_imm[disp.b_rs_idx] <= rou_exu.uop_b.imm;
        rs_pc[disp.b_rs_idx] <= rou_exu.uop_b.pc;
        rs_b_block[disp.b_rs_idx] <= (rou_exu.uop_b.system || rou_exu.uop_b.trap
                                    || rou_exu.uop_b.ecall  || rou_exu.uop_b.ebreak
                                    || rou_exu.uop_b.mret   || rou_exu.uop_b.sret
                                    || (rou_exu.uop_b.csr_csw != 0));
        rs_trap[disp.b_rs_idx] <= rou_exu.uop_b.trap;
        rs_tval[disp.b_rs_idx] <= rou_exu.uop_b.tval;
        rs_cause[disp.b_rs_idx] <= rou_exu.uop_b.cause;
      end
`endif

      // ---- Age matrix updates on allocation ----
      // Newly allocated entry is youngest: zero its row, set its column to
      // currently-valid entries (older). NBA semantics let same-cycle B
      // override A's column entry to mark A as older than B.
      if (disp.accept_a) begin
        for (int j = 0; j < RS_SIZE; j++) begin
          age_mat[free_idx_a][j] <= 1'b0;
          if (j != int'(free_idx_a)) age_mat[j][free_idx_a] <= rs_valid[j];
        end
      end
`ifdef RAPT_DUAL_ISSUE
      if (disp.accept_b) begin
        for (int j = 0; j < RS_SIZE; j++) begin
          age_mat[disp.b_rs_idx][j] <= 1'b0;
          if (j != int'(disp.b_rs_idx)) age_mat[j][disp.b_rs_idx] <= rs_valid[j];
        end
        // If A also allocated this cycle, A is older than B.
        if (disp.accept_a) begin
          age_mat[free_idx_a][disp.b_rs_idx] <= 1'b1;
        end
      end
`endif
    end
  end

  // === Slot-A writeback (full path: ALU + CSR + system + trap) ===
  logic [XLEN-1:0] addr_exu_a;
  logic [XLEN-1:0] csr_wdata_a;
  assign addr_exu_a = ((rs_jump[valid_idx_a]
      ? rs_vj[valid_idx_a]
      : rs_pc[valid_idx_a]) + rs_imm[valid_idx_a]) & ~'b1;

  assign exu_csr.raddr = rs_imm[valid_idx_a][11:0];
  assign csr_wdata_a = (
      ({XLEN{rs_pl_a.csr_csw[0]}} & rs_vj[valid_idx_a]) |
      ({XLEN{rs_pl_a.csr_csw[1]}} & (exu_csr.rdata | rs_vj[valid_idx_a])) |
      ({XLEN{rs_pl_a.csr_csw[2]}} & (exu_csr.rdata & ~rs_vj[valid_idx_a])) |
      (0)
  );

  // instret correction: account for in-flight ROB entries before this CSR read.
  logic [$clog2(ROB_SIZE)-1:0] instret_correction_a;
  logic                        is_instret_read_a;
  assign instret_correction_a = (rs_dest[valid_idx_a] - cmu_bcast.rob_head + 1'b1);
  assign is_instret_read_a = (rs_imm[valid_idx_a][11:0] ==
      `RAPT_CSR_INSTRET_
      || rs_imm[valid_idx_a][11:0] == `RAPT_CSR_MINSTRET);
  logic [XLEN-1:0] csr_rdata_corrected_a;
  assign csr_rdata_corrected_a = is_instret_read_a
      ? (exu_csr.rdata + XLEN'(instret_correction_a))
      : exu_csr.rdata;

  assign exu_rou.dest = rs_dest[valid_idx_a];
  assign exu_rou.result  = (rs_pl_a.sys
      ? csr_rdata_corrected_a
      : (rs_alu[valid_idx_a][5:4] == 2'b01
          ? rs_mul_a[valid_idx_a]
          : rs_jen[valid_idx_a]
              ? rs_pc[valid_idx_a] + (rs_c[valid_idx_a] ? 2 : 4)
              : alu_result_a));
  assign exu_rou.npc = (
      (rs_pl_a.ecall || rs_pl_a.ebreak)
      ? csr_bcast.mtvec
      : rs_trap[valid_idx_a]
          ? csr_bcast.tvec
          : rs_pl_a.mret
              ? exu_csr.mepc
              : rs_pl_a.sret
                  ? exu_csr.sepc
                  : (rs_br_jmp[valid_idx_a]) || (rs_br_cond[valid_idx_a] && |alu_result_a)
                      ? addr_exu_a
                      : (rs_pc[valid_idx_a] + (rs_c[valid_idx_a] ? 2 : 4)));
  assign exu_rou.btaken = (rs_br_cond[valid_idx_a] && |alu_result_a);
  assign exu_rou.prd = rs_prd[valid_idx_a];
  assign exu_rou.rd = rs_rd[valid_idx_a];
  assign exu_rou.pc = rs_pc[valid_idx_a];
  assign exu_rou.csr_wen = |rs_pl_a.csr_csw;
  assign exu_rou.csr_wdata = csr_wdata_a;
  assign exu_rou.trap = rs_trap[valid_idx_a];
  assign exu_rou.tval = rs_tval[valid_idx_a];
  assign exu_rou.cause = rs_cause[valid_idx_a];
  assign exu_rou.difftest_skip = |rs_pl_a.csr_csw && (rs_imm[valid_idx_a][11:0] ==
      `RAPT_CSR_TIME___
      || rs_imm[valid_idx_a][11:0] ==
      `RAPT_CSR_TIMEH__
      || rs_imm[valid_idx_a][11:0] ==
      `RAPT_CSR_CYCLE__
      || rs_imm[valid_idx_a][11:0] ==
      `RAPT_CSR_MCYCLE_
      || rs_imm[valid_idx_a][11:0] == `RAPT_CSR_MCYCLEH);
  assign exu_rou.valid = valid_found_a;

  // === Slot-B writeback (pure ALU + jen) ===
  logic [XLEN-1:0] addr_exu_b;
  assign addr_exu_b = ((rs_jump[valid_idx_b]
      ? rs_vj[valid_idx_b]
      : rs_pc[valid_idx_b]) + rs_imm[valid_idx_b]) & ~'b1;

  assign exu_rou_b.valid = valid_found_b;
  assign exu_rou_b.dest = rs_dest[valid_idx_b];
  assign exu_rou_b.result = rs_jen[valid_idx_b]
      ? rs_pc[valid_idx_b] + (rs_c[valid_idx_b] ? 2 : 4)
      : alu_result_b;
  assign exu_rou_b.prd = rs_prd[valid_idx_b];
  assign exu_rou_b.rd = rs_rd[valid_idx_b];
  assign exu_rou_b.pc = rs_pc[valid_idx_b];
  assign exu_rou_b.npc    =
      (rs_br_jmp[valid_idx_b] || (rs_br_cond[valid_idx_b] && |alu_result_b))
      ? addr_exu_b
      : rs_pc[valid_idx_b] + (rs_c[valid_idx_b] ? 2 : 4);
  assign exu_rou_b.btaken = (rs_br_cond[valid_idx_b] && |alu_result_b);
  assign exu_rou_b.difftest_skip = 1'b0;

  // === Port-C writeback (BRU only) ===
  logic [XLEN-1:0] addr_exu_c;
  assign addr_exu_c = (rs_pc[valid_idx_c] + rs_imm[valid_idx_c]) & ~'b1;

  assign exu_rou_c.valid = valid_found_c;
  assign exu_rou_c.dest = rs_dest[valid_idx_c];
  assign exu_rou_c.pc = rs_pc[valid_idx_c];
  assign exu_rou_c.npc    = (|alu_result_c)
      ? addr_exu_c
      : rs_pc[valid_idx_c] + (rs_c[valid_idx_c] ? 2 : 4);
  assign exu_rou_c.btaken = |alu_result_c;
  assign exu_rou_c.difftest_skip = 1'b0;

endmodule

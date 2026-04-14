`include "ysyx.svh"
`include "ysyx_if.svh"

module ysyx_exu #(
    parameter unsigned RS_SIZE = `YSYX_RS_SIZE,
    parameter unsigned IOQ_SIZE = `YSYX_IOQ_SIZE,
    parameter unsigned ROB_SIZE = `YSYX_ROB_SIZE,
    parameter unsigned PLEN = `YSYX_PHY_LEN,
    parameter unsigned RLEN = `YSYX_REG_LEN,
    parameter unsigned XLEN = `YSYX_XLEN
) (
    input clock,

    cmu_bcast_if.in cmu_bcast,

    rou_exu_if.slave rou_exu,

    exu_rou_if.out exu_rou,
    exu_ioq_bcast_if.out exu_ioq_bcast,

    exu_lsu_if.master exu_lsu,
    exu_csr_if.master exu_csr,

    csr_bcast_if.in   csr_bcast,
    exu_l1d_if.master exu_l1d,

    input reset
);
  logic [XLEN-1:0] reg_wdata_mul;
  logic [XLEN-1:0] addr_exu;
  logic [XLEN-1:0] csr_wdata;

  logic mul_valid;
  logic [XLEN-1:0] alu_result;

  // === Revervation Station (RS) ===
  logic [RS_SIZE-1:0] rs_valid;

  logic [32-1:0] rs_inst[RS_SIZE];
  logic [XLEN-1:0] rs_pc[RS_SIZE];

  logic rs_c[RS_SIZE];
  logic rs_word[RS_SIZE];
  logic [5:0] rs_alu[RS_SIZE];
  logic [XLEN-1:0] rs_vj[RS_SIZE];
  logic [XLEN-1:0] rs_vk[RS_SIZE];
  logic [$clog2(ROB_SIZE):0] rs_dest[RS_SIZE];

  logic [PLEN-1:0] rs_pr1[RS_SIZE];
  logic [PLEN-1:0] rs_pr2[RS_SIZE];
  logic [PLEN-1:0] rs_prd[RS_SIZE];
  logic [RLEN-1:0] rs_rd[RS_SIZE];

  logic [RS_SIZE-1:0] rs_mul_ready;
  logic [XLEN-1:0] rs_mul_a[RS_SIZE];

  logic [RS_SIZE-1:0] rs_jen;
  logic [RS_SIZE-1:0] rs_br_jmp;
  logic [RS_SIZE-1:0] rs_br_cond;
  logic [RS_SIZE-1:0] rs_jump;
  logic [XLEN-1:0] rs_imm[RS_SIZE];

  logic [RS_SIZE-1:0] rs_system;
  logic [RS_SIZE-1:0] rs_ecall;
  logic [RS_SIZE-1:0] rs_ebreak;
  logic [RS_SIZE-1:0] rs_mret;
  logic [RS_SIZE-1:0] rs_sret;
  logic [2:0] rs_csr_csw[RS_SIZE];

  logic rs_trap[RS_SIZE];
  logic [XLEN-1:0] rs_tval[RS_SIZE];
  logic [XLEN-1:0] rs_cause[RS_SIZE];
  logic rs_ready;
  // === Revervation Station (RS) ===

  // === In-Order Queue (IOQ), for Load, Store ===
  logic [IOQ_SIZE-1:0] ioq_valid;
  logic [$clog2(IOQ_SIZE)-1:0] ioq_tail;
  logic [$clog2(IOQ_SIZE)-1:0] ioq_head;

  logic [32-1:0] ioq_inst[IOQ_SIZE];
  logic [XLEN-1:0] ioq_pc[IOQ_SIZE];

  logic [PLEN-1:0] ioq_pr1[IOQ_SIZE];
  logic [PLEN-1:0] ioq_pr2[IOQ_SIZE];
  logic [PLEN-1:0] ioq_prd[IOQ_SIZE];
  logic [RLEN-1:0] ioq_rd[IOQ_SIZE];

  logic ioq_c[IOQ_SIZE];
  logic ioq_word[IOQ_SIZE];
  logic [5:0] ioq_alu[IOQ_SIZE];
  logic [XLEN-1:0] ioq_vj[IOQ_SIZE];
  logic [XLEN-1:0] ioq_vk[IOQ_SIZE];
  logic [$clog2(ROB_SIZE):0] ioq_dest[IOQ_SIZE];
  logic [XLEN-1:0] ioq_imm[IOQ_SIZE];

  logic [XLEN-1:0] ioq_data[IOQ_SIZE];

  logic [IOQ_SIZE-1:0] ioq_wen;
  logic [IOQ_SIZE-1:0] ioq_mmu_en;
  logic [IOQ_SIZE-1:0] ioq_trap;
  logic [XLEN-1:0] ioq_cause[IOQ_SIZE];
  logic [XLEN-1:0] ioq_paddr[IOQ_SIZE];
  logic [IOQ_SIZE-1:0] ioq_ren;
  logic [IOQ_SIZE-1:0] ioq_atom;

  logic ioq_ready;
  // === In-Order Queue (IOQ), for Load, Store ===

  logic reservation_match;

  logic [$clog2(RS_SIZE)-1:0] free_idx_a;
  logic free_found_a;
`ifdef YSYX_DUAL_ISSUE
  logic [$clog2(RS_SIZE)-1:0] free_idx_b;
  logic free_found_b;
`endif

  logic [$clog2(RS_SIZE)-1:0] valid_idx;
  logic [$clog2(RS_SIZE)-1:0] mul_rs_idx;
  logic valid_found, mul_found, ioq_valid_found;

  // One-hot match vectors for priority encoding (replaces for-loop traversal)
  logic [RS_SIZE-1:0] rs_free_vec;
  logic [RS_SIZE-1:0] rs_ready_vec;
  logic [RS_SIZE-1:0] rs_mul_vec;

  always_comb begin
    for (int i = 0; i < RS_SIZE; i++) begin
      rs_free_vec[i]  = !rs_valid[i];
      rs_ready_vec[i] = rs_valid[i] && rs_pr1[i] == 0 && rs_pr2[i] == 0
                       && (rs_alu[i][5:4] != 2'b01 || rs_mul_ready[i]);
      rs_mul_vec[i]   = rs_valid[i] && rs_alu[i][5:4] == 2'b01;
    end
  end

  // Priority encode: lowest-index-first (parameterized for RS_SIZE)
  always_comb begin
    free_idx_a = '0;
    free_found_a = 0;
    for (int i = 0; i < RS_SIZE; i++) begin
      if (!free_found_a && rs_free_vec[i]) begin
        free_idx_a = i[$clog2(RS_SIZE)-1:0];
        free_found_a = 1;
      end
    end

    valid_idx = '0;
    valid_found = 0;
    for (int i = 0; i < RS_SIZE; i++) begin
      if (!valid_found && rs_ready_vec[i]) begin
        valid_idx = i[$clog2(RS_SIZE)-1:0];
        valid_found = 1;
      end
    end

    mul_rs_idx = '0;
    mul_found = 0;
    for (int i = 0; i < RS_SIZE; i++) begin
      if (!mul_found && rs_mul_vec[i]) begin
        mul_rs_idx = i[$clog2(RS_SIZE)-1:0];
        mul_found = 1;
      end
    end
  end

`ifdef YSYX_DUAL_ISSUE
  // Second free RS entry (for dual RS dispatch)
  always_comb begin
    free_idx_b = '0;
    free_found_b = 0;
    for (int i = 0; i < RS_SIZE; i++) begin
      if (!free_found_b
        && rs_free_vec[i] && !(free_found_a && i[$clog2(RS_SIZE)-1:0] == free_idx_a)) begin
        free_idx_b = i[$clog2(RS_SIZE)-1:0];
        free_found_b = 1;
      end
    end
  end
`endif

  // Uncacheable loads (MMIO) defer to ROB head (non-speculative) when MMU is off.
  // When MMU is on, TLB handles address gating inside L1D.
  logic ioq_at_rob_head;
  assign ioq_at_rob_head = (ioq_dest[ioq_head] == cmu_bcast.rob_head + 1);

  assign exu_lsu.rvalid = (ioq_valid[ioq_head]
    && ioq_ren[ioq_head]
    && ioq_pr1[ioq_head] == 0 && ioq_pr2[ioq_head] == 0
    && (csr_bcast.dmmu_en || ysyx_pkg::addr_cacheable(exu_lsu.raddr) || ioq_at_rob_head));
  assign exu_lsu.raddr = ioq_atom[ioq_head]
    ? ioq_vj[ioq_head]
    : ioq_vj[ioq_head] + ioq_imm[ioq_head];
  assign exu_lsu.ralu = ioq_atom[ioq_head] ? `YSYX_ALU_LW__ : ioq_alu[ioq_head][4:0];
  assign exu_lsu.atomic_lock = ioq_atom[ioq_head] && ioq_alu[ioq_head] == `YSYX_ATO_LR__;
  assign exu_lsu.pc = ioq_pc[ioq_head];

  assign ioq_ready = ioq_valid[ioq_tail] == 0;
  assign rs_ready = ((rou_exu.uop.wen || rou_exu.uop.ren)
    ? ioq_ready
    : free_found_a && !(mul_found && rou_exu.uop.alu[5:4] == 2'b01));
  assign rou_exu.ready = rs_ready;

`ifdef YSYX_DUAL_ISSUE
  // Slot B readiness: depends on slot A's target queue
  logic [$clog2(IOQ_SIZE)-1:0] ioq_tail_b;
  assign ioq_tail_b = ioq_tail + 1;

  logic a_to_ioq, b_to_ioq;
  assign a_to_ioq = (rou_exu.uop.wen || rou_exu.uop.ren);
  assign b_to_ioq = (rou_exu.uop_b.wen || rou_exu.uop_b.ren);

  logic rs_ready_b;
  always_comb begin
    if (b_to_ioq) begin
      // Slot B goes to IOQ
      if (a_to_ioq)
        rs_ready_b = (ioq_valid[ioq_tail] == 0) && (ioq_valid[ioq_tail_b] == 0);
      else
        rs_ready_b = ioq_ready;
    end else begin
      // Slot B goes to RS
      if (a_to_ioq)
        rs_ready_b = free_found_a && !(mul_found && rou_exu.uop_b.alu[5:4] == 2'b01);
      else
        rs_ready_b = free_found_b && !(mul_found && rou_exu.uop_b.alu[5:4] == 2'b01);
    end
  end
  assign rou_exu.ready_b = rs_ready_b;

  // Index for slot B RS dispatch: if A->IOQ, B takes first free; if A->RS, B takes second free
  logic [$clog2(RS_SIZE)-1:0] b_rs_idx;
  assign b_rs_idx = a_to_ioq ? free_idx_a : free_idx_b;
`endif

  ysyx_exu_alu gen_alu (
      .s1(rs_vj[valid_idx]),
      .s2(rs_vk[valid_idx]),
      .op(rs_alu[valid_idx]),
      .word(rs_word[valid_idx]),
      .out_r(alu_result)
  );
  logic muling;
  logic [$clog2(RS_SIZE)-1:0] mul_target_idx;  // RS entry whose multiply is in-flight

  always @(posedge clock) begin
    if (reset || cmu_bcast.flush_pipe) begin
      ioq_ren <= 0;
      ioq_wen <= 0;
      ioq_mmu_en <= 0;
      rs_valid <= 0;
      rs_mul_ready <= 0;
      muling <= 0;

      ioq_valid <= 0;
      ioq_head <= 0;
      ioq_tail <= 0;
    end else begin
      // In-Order Queue (IOQ)
      if (rou_exu.valid && ioq_ready && (rou_exu.uop.wen || rou_exu.uop.ren)) begin
        // Dispatch slot A to IOQ
        ioq_valid[ioq_tail] <= 1;

        ioq_inst[ioq_tail] <= rou_exu.uop.inst;
        ioq_pc[ioq_tail] <= rou_exu.uop.pc;

        ioq_pr1[ioq_tail] <= rou_exu.pr1;
        ioq_pr2[ioq_tail] <= rou_exu.pr2;
        ioq_prd[ioq_tail] <= rou_exu.prd;
        ioq_rd[ioq_tail] <= rou_exu.uop.rd;

        ioq_c[ioq_tail] <= rou_exu.uop.c;
        ioq_word[ioq_tail] <= rou_exu.uop.word;
        ioq_alu[ioq_tail] <= rou_exu.uop.alu;
        ioq_vj[ioq_tail] <= rou_exu.op1;
        ioq_vk[ioq_tail] <= rou_exu.op2;
        ioq_dest[ioq_tail] <= rou_exu.dest;

        ioq_imm[ioq_tail] <= rou_exu.uop.imm;

        ioq_wen[ioq_tail] <= rou_exu.uop.wen;
        ioq_mmu_en[ioq_tail] <= csr_bcast.dmmu_en;
        ioq_ren[ioq_tail] <= rou_exu.uop.ren;
        ioq_atom[ioq_tail] <= rou_exu.uop.atom;
        ioq_trap[ioq_tail] <= rou_exu.uop.trap;

`ifdef YSYX_DUAL_ISSUE
        // Check if slot B also goes to IOQ
        if (rou_exu.valid_b && rs_ready_b && b_to_ioq) begin
          ioq_valid[ioq_tail_b] <= 1;
          ioq_inst[ioq_tail_b] <= rou_exu.uop_b.inst;

          ioq_pc[ioq_tail_b] <= rou_exu.uop_b.pc;
          ioq_pr1[ioq_tail_b] <= rou_exu.pr1_b;
          ioq_pr2[ioq_tail_b] <= rou_exu.pr2_b;
          ioq_prd[ioq_tail_b] <= rou_exu.prd_b;
          ioq_rd[ioq_tail_b] <= rou_exu.uop_b.rd;

          ioq_c[ioq_tail_b] <= rou_exu.uop_b.c;
          ioq_word[ioq_tail_b] <= rou_exu.uop_b.word;
          ioq_alu[ioq_tail_b] <= rou_exu.uop_b.alu;
          ioq_vj[ioq_tail_b] <= rou_exu.op1_b;
          ioq_vk[ioq_tail_b] <= rou_exu.op2_b;
          ioq_dest[ioq_tail_b] <= rou_exu.dest_b;

          ioq_imm[ioq_tail_b] <= rou_exu.uop_b.imm;

          ioq_wen[ioq_tail_b] <= rou_exu.uop_b.wen;
          ioq_mmu_en[ioq_tail_b] <= csr_bcast.dmmu_en;
          ioq_ren[ioq_tail_b] <= rou_exu.uop_b.ren;
          ioq_atom[ioq_tail_b] <= rou_exu.uop_b.atom;
          ioq_trap[ioq_tail_b] <= rou_exu.uop_b.trap;
          ioq_tail <= (ioq_tail + 2);
        end else begin
          ioq_tail <= (ioq_tail + 1);
        end
`else
        ioq_tail <= (ioq_tail + 1);
`endif
      end
`ifdef YSYX_DUAL_ISSUE
      // Slot B -> IOQ when slot A -> RS (slot A didn't go to IOQ)
      else if (rou_exu.valid_b && rs_ready_b && b_to_ioq && !a_to_ioq) begin
        ioq_valid[ioq_tail] <= 1;
        ioq_inst[ioq_tail] <= rou_exu.uop_b.inst;

        ioq_pc[ioq_tail] <= rou_exu.uop_b.pc;
        ioq_pr1[ioq_tail] <= rou_exu.pr1_b;
        ioq_pr2[ioq_tail] <= rou_exu.pr2_b;
        ioq_prd[ioq_tail] <= rou_exu.prd_b;
        ioq_rd[ioq_tail] <= rou_exu.uop_b.rd;

        ioq_c[ioq_tail] <= rou_exu.uop_b.c;
        ioq_word[ioq_tail] <= rou_exu.uop_b.word;
        ioq_alu[ioq_tail] <= rou_exu.uop_b.alu;
        ioq_vj[ioq_tail] <= rou_exu.op1_b;
        ioq_vk[ioq_tail] <= rou_exu.op2_b;
        ioq_dest[ioq_tail] <= rou_exu.dest_b;

        ioq_imm[ioq_tail] <= rou_exu.uop_b.imm;

        ioq_wen[ioq_tail] <= rou_exu.uop_b.wen;
        ioq_mmu_en[ioq_tail] <= csr_bcast.dmmu_en;
        ioq_ren[ioq_tail] <= rou_exu.uop_b.ren;
        ioq_atom[ioq_tail] <= rou_exu.uop_b.atom;
        ioq_trap[ioq_tail] <= rou_exu.uop_b.trap;
        ioq_tail <= (ioq_tail + 1);
      end
`endif
      if (exu_l1d.ready && ioq_mmu_en[ioq_head]) begin
        ioq_paddr[ioq_head]  <= exu_l1d.paddr;
        ioq_mmu_en[ioq_head] <= 0;
        ioq_trap[ioq_head]   <= exu_l1d.trap;
        ioq_cause[ioq_head]  <= exu_l1d.cause;
      end
      if (ioq_valid_found) begin
        // Write back of IOQ
        ioq_inst[ioq_head] <= 0;

        ioq_wen[ioq_head] <= 0;
        ioq_mmu_en[ioq_head] <= 0;
        ioq_trap[ioq_head] <= 0;
        ioq_ren[ioq_head] <= 0;
        ioq_valid[ioq_head] <= 0;
        ioq_head <= (ioq_head + 1);
      end
      for (bit [XLEN-1:0] i = 0; i < IOQ_SIZE; i++) begin
        if (ioq_valid[i]) begin
          if (|ioq_pr1[i]) begin
            if (exu_ioq_bcast.valid && exu_ioq_bcast.prd == ioq_pr1[i]) begin
              // Forwarding from IOQ
              ioq_vj[i]  <= exu_ioq_bcast.result;
              ioq_pr1[i] <= 0;  // Clear physical register
            end else if (exu_rou.valid && exu_rou.prd == ioq_pr1[i]) begin
              // Forwarding from RS
              ioq_vj[i]  <= exu_rou.result;
              ioq_pr1[i] <= 0;  // Clear physical register
            end
          end
          if (|ioq_pr2[i]) begin
            if (exu_ioq_bcast.valid && exu_ioq_bcast.prd == ioq_pr2[i]) begin
              // Forwarding from IOQ
              ioq_vk[i]  <= exu_ioq_bcast.result;
              ioq_pr2[i] <= 0;  // Clear physical register
            end else if (exu_rou.valid && exu_rou.prd == ioq_pr2[i]) begin
              // Forwarding from RS
              ioq_vk[i]  <= exu_rou.result;
              ioq_pr2[i] <= 0;  // Clear physical register
            end
          end
        end
      end
      // Reservation Station (RS)
      for (bit [XLEN-1:0] i = 0; i < RS_SIZE; i++) begin
        if (free_found_a && i[$clog2(RS_SIZE)-1:0] == free_idx_a) begin
          if (rou_exu.valid && rs_ready && !(rou_exu.uop.wen || rou_exu.uop.ren)) begin
            // Dispatch slot A to RS
            rs_valid[free_idx_a] <= 1;
            rs_alu[free_idx_a] <= rou_exu.uop.alu;
            rs_vj[free_idx_a] <= rou_exu.op1;
            rs_vk[free_idx_a] <= rou_exu.op2;
            rs_dest[free_idx_a] <= rou_exu.dest;

            rs_pr1[free_idx_a] <= rou_exu.pr1;
            rs_pr2[free_idx_a] <= rou_exu.pr2;
            rs_prd[free_idx_a] <= rou_exu.prd;
            rs_rd[free_idx_a] <= rou_exu.uop.rd;

            rs_c[free_idx_a] <= rou_exu.uop.c;
            rs_word[free_idx_a] <= rou_exu.uop.word;
            rs_jen[free_idx_a] <= rou_exu.uop.jen;
            rs_br_jmp[free_idx_a] <= (rou_exu.uop.jen || rou_exu.uop.ecall || rou_exu.uop.mret);
            rs_br_cond[free_idx_a] <= (rou_exu.uop.ben);
            rs_jump[free_idx_a] <= (rou_exu.uop.jen);
            rs_imm[free_idx_a] <= rou_exu.uop.imm;
            rs_pc[free_idx_a] <= rou_exu.uop.pc;
            rs_inst[free_idx_a] <= rou_exu.uop.inst;

            rs_system[free_idx_a] <= rou_exu.uop.system;
            rs_ecall[free_idx_a] <= rou_exu.uop.ecall;
            rs_ebreak[free_idx_a] <= rou_exu.uop.ebreak;
            rs_mret[free_idx_a] <= rou_exu.uop.mret;
            rs_sret[free_idx_a] <= rou_exu.uop.sret;
            rs_csr_csw[free_idx_a] <= rou_exu.uop.csr_csw;

            rs_trap[free_idx_a] <= rou_exu.uop.trap;
            rs_tval[free_idx_a] <= rou_exu.uop.tval;
            rs_cause[free_idx_a] <= rou_exu.uop.cause;
          end
        end else if (rs_valid[i] && rs_pr1[i] == 0 && rs_pr2[i] == 0) begin
          // Mul
          if (rs_alu[i][5:4] == 2'b01) begin
            if (rs_mul_ready[i] == 0 && muling == 0
                && i[$clog2(RS_SIZE)-1:0] == mul_rs_idx) begin
              // Mul start: only the entry selected by the priority encoder
              muling <= 1;
              mul_target_idx <= i[$clog2(RS_SIZE)-1:0];
            end
            if (i[$clog2(RS_SIZE)-1:0] == mul_target_idx
                && muling == 1 && mul_valid) begin
              // Mul result is ready: deliver only to the entry that started it
              rs_mul_ready[i] <= 1;
              muling <= 0;
              rs_mul_a[i] <= reg_wdata_mul;
            end
          end
          if (valid_found && valid_idx == i[$clog2(RS_SIZE)-1:0]) begin
            // Write back and clear RS
            rs_valid[i] <= 0;
            rs_alu[i] <= 0;
            rs_inst[i] <= 0;
            rs_mul_ready[i] <= 0;
          end
        end else if (rs_valid[i]) begin
          if (|rs_pr1[i] && exu_ioq_bcast.valid && exu_ioq_bcast.prd == rs_pr1[i]) begin
            // Forwarding from IOQ
            rs_vj[i]  <= exu_ioq_bcast.result;
            rs_pr1[i] <= 0;  // Clear physical register
          end else if (|rs_pr1[i] && exu_rou.valid && exu_rou.prd == rs_pr1[i]) begin
            // Forwarding from RS
            rs_vj[i]  <= exu_rou.result;
            rs_pr1[i] <= 0;  // Clear physical register
          end
          if (|rs_pr2[i] && exu_ioq_bcast.valid && exu_ioq_bcast.prd == rs_pr2[i]) begin
            // Forwarding from IOQ
            rs_vk[i]  <= exu_ioq_bcast.result;
            rs_pr2[i] <= 0;  // Clear physical register
          end else if (|rs_pr2[i] && exu_rou.valid && exu_rou.prd == rs_pr2[i]) begin
            // Forwarding from RS
            rs_vk[i]  <= exu_rou.result;
            rs_pr2[i] <= 0;  // Clear physical register
          end
        end
      end
`ifdef YSYX_DUAL_ISSUE
      // Slot B -> RS dispatch (standalone block, targets b_rs_idx)
      if (rou_exu.valid_b && rs_ready_b && !b_to_ioq) begin
        rs_valid[b_rs_idx] <= 1;
        rs_alu[b_rs_idx] <= rou_exu.uop_b.alu;
        rs_vj[b_rs_idx] <= rou_exu.op1_b;
        rs_vk[b_rs_idx] <= rou_exu.op2_b;
        rs_dest[b_rs_idx] <= rou_exu.dest_b;

        rs_pr1[b_rs_idx] <= rou_exu.pr1_b;
        rs_pr2[b_rs_idx] <= rou_exu.pr2_b;
        rs_prd[b_rs_idx] <= rou_exu.prd_b;
        rs_rd[b_rs_idx] <= rou_exu.uop_b.rd;

        rs_c[b_rs_idx] <= rou_exu.uop_b.c;
        rs_word[b_rs_idx] <= rou_exu.uop_b.word;
        rs_jen[b_rs_idx] <= rou_exu.uop_b.jen;
        rs_br_jmp[b_rs_idx] <= (rou_exu.uop_b.jen || rou_exu.uop_b.ecall || rou_exu.uop_b.mret);
        rs_br_cond[b_rs_idx] <= (rou_exu.uop_b.ben);
        rs_jump[b_rs_idx] <= (rou_exu.uop_b.jen);

        rs_imm[b_rs_idx] <= rou_exu.uop_b.imm;

        rs_pc[b_rs_idx] <= rou_exu.uop_b.pc;
        rs_inst[b_rs_idx] <= rou_exu.uop_b.inst;
        rs_system[b_rs_idx] <= rou_exu.uop_b.system;
        rs_ecall[b_rs_idx] <= rou_exu.uop_b.ecall;
        rs_ebreak[b_rs_idx] <= rou_exu.uop_b.ebreak;
        rs_mret[b_rs_idx] <= rou_exu.uop_b.mret;
        rs_sret[b_rs_idx] <= rou_exu.uop_b.sret;
        rs_csr_csw[b_rs_idx] <= rou_exu.uop_b.csr_csw;

        rs_trap[b_rs_idx] <= rou_exu.uop_b.trap;
        rs_tval[b_rs_idx] <= rou_exu.uop_b.tval;
        rs_cause[b_rs_idx] <= rou_exu.uop_b.cause;
      end
`endif
    end
  end

  always_comb begin
    for (bit [XLEN-1:0] i = 0; i < IOQ_SIZE; i++) begin
      if (ioq_atom[i]) begin
        case (ioq_alu[i])
          `YSYX_ATO_LR__: begin
            ioq_data[i] = 'b0;
          end
          `YSYX_ATO_SC__: begin
            ioq_data[i] = ioq_vk[i];
          end
          `YSYX_ATO_SWAP: begin
            ioq_data[i] = ioq_vk[i];
          end
          `YSYX_ATO_ADD_: begin
            ioq_data[i] = ioq_vk[i] + exu_lsu.rdata;
          end
          `YSYX_ATO_XOR_: begin
            ioq_data[i] = ioq_vk[i] ^ exu_lsu.rdata;
          end
          `YSYX_ATO_AND_: begin
            ioq_data[i] = ioq_vk[i] & exu_lsu.rdata;
          end
          `YSYX_ATO_OR__: begin
            ioq_data[i] = ioq_vk[i] | exu_lsu.rdata;
          end
          `YSYX_ATO_MIN_: begin
            ioq_data[i] = $signed(exu_lsu.rdata) < $signed(ioq_vk[i]) ? exu_lsu.rdata : ioq_vk[i];
          end
          `YSYX_ATO_MAX_: begin
            ioq_data[i] = $signed(exu_lsu.rdata) > $signed(ioq_vk[i]) ? exu_lsu.rdata : ioq_vk[i];
          end
          `YSYX_ATO_MINU: begin
            ioq_data[i] = exu_lsu.rdata < ioq_vk[i] ? exu_lsu.rdata : ioq_vk[i];
          end
          `YSYX_ATO_MAXU: begin
            ioq_data[i] = exu_lsu.rdata > ioq_vk[i] ? exu_lsu.rdata : ioq_vk[i];
          end
          default: begin
            ioq_data[i] = 'b0;
          end
        endcase
      end else begin
        ioq_data[i] = ioq_vk[i];
      end
    end
  end

  // MMU for Store
  assign exu_l1d.mmu_en = (ioq_wen[ioq_head]
    && ioq_mmu_en[ioq_head]
    && ioq_pr1[ioq_head] == 0
    && ioq_pr2[ioq_head] == 0);
  assign exu_l1d.vaddr = ioq_vj[ioq_head] + ioq_imm[ioq_head];
  assign exu_l1d.walu = ioq_alu[ioq_head][4:0];
  assign exu_l1d.valid = (ioq_wen[ioq_head] && ioq_pr1[ioq_head] == 0 && ioq_pr2[ioq_head] == 0);

  // Branch
  assign addr_exu = ((rs_jump[valid_idx]
    ? rs_vj[valid_idx]
    : rs_pc[valid_idx]) + rs_imm[valid_idx]) & ~'b1;

  assign reservation_match = exu_l1d.reservation == (csr_bcast.dmmu_en
    ? ioq_paddr[ioq_head]
    : (ioq_vj[ioq_head] + ioq_imm[ioq_head]));
  // { Write back (IOQ)
  assign exu_ioq_bcast.pc = ioq_pc[ioq_head];
  assign exu_ioq_bcast.npc = ioq_ren[ioq_head]
    ? (exu_lsu.trap
      ? csr_bcast.tvec
      : ioq_pc[ioq_head] + (ioq_c[ioq_head] ? 2 : 4))
    : ioq_trap[ioq_head]
      ? csr_bcast.tvec
      : ioq_pc[ioq_head] + (ioq_c[ioq_head] ? 2 : 4);
  assign exu_ioq_bcast.result = (ioq_atom[ioq_head] && ioq_alu[ioq_head] == `YSYX_ATO_SC__)
    ? (reservation_match ? 0 : 1)
    : (exu_lsu.rready
      ? exu_lsu.rdata
      : ioq_data[ioq_head]);
  assign exu_ioq_bcast.dest = ioq_dest[ioq_head];

  assign exu_ioq_bcast.prd = ioq_prd[ioq_head];
  assign exu_ioq_bcast.rd = ioq_rd[ioq_head];

  assign exu_ioq_bcast.wen = (ioq_atom[ioq_head] && ioq_alu[ioq_head] == `YSYX_ATO_SC__)
    ? (reservation_match ? 1 : 0)
    : (ioq_wen[ioq_head]);
  assign exu_ioq_bcast.alu = ioq_alu[ioq_head];
  assign exu_ioq_bcast.sq_waddr = csr_bcast.dmmu_en
    ? ioq_paddr[ioq_head]
    : ioq_vj[ioq_head] + ioq_imm[ioq_head];
  assign exu_ioq_bcast.sq_wdata = ioq_data[ioq_head];

  assign exu_ioq_bcast.trap = ioq_ren[ioq_head] ? exu_lsu.trap : ioq_trap[ioq_head];
  assign exu_ioq_bcast.tval = ioq_ren[ioq_head]
    ? exu_lsu.raddr
    : ioq_vj[ioq_head] + ioq_imm[ioq_head];
  assign exu_ioq_bcast.cause = ioq_ren[ioq_head] ? exu_lsu.cause : ioq_cause[ioq_head];
  assign exu_ioq_bcast.inst = exu_lsu.trap || ioq_trap[ioq_head] ? 'h13 : ioq_inst[ioq_head];

  // Difftest: detect MMIO access for loads (from LSU) and stores (by address check)
  assign exu_ioq_bcast.difftest_skip =
      (ioq_ren[ioq_head] && exu_lsu.difftest_skip)
    || (ioq_wen[ioq_head] && ysyx_pkg::addr_mmio(exu_ioq_bcast.sq_waddr));

  assign ioq_valid_found = (ioq_valid[ioq_head]
    && ioq_pr1[ioq_head] == 0 && ioq_pr2[ioq_head] == 0
    && (ioq_ren[ioq_head]
        ? exu_lsu.rready
        : ioq_mmu_en[ioq_head] == 0)
    && (!ioq_wen[ioq_head] || ioq_mmu_en[ioq_head] == 0)
  );
  assign exu_ioq_bcast.valid = ioq_valid_found;
  // } Write back (IOQ)


  // Zicsr
  assign exu_csr.raddr = rs_imm[valid_idx][11:0];
  assign csr_wdata = (
    ({XLEN{rs_csr_csw[valid_idx][0]}} & rs_vj[valid_idx]) |
    ({XLEN{rs_csr_csw[valid_idx][1]}} & (exu_csr.rdata | rs_vj[valid_idx])) |
    ({XLEN{rs_csr_csw[valid_idx][2]}} & (exu_csr.rdata & ~rs_vj[valid_idx])) |
    (0)
  );

  // instret correction: account for in-flight ROB entries before this CSR read
  logic [$clog2(ROB_SIZE)-1:0] instret_correction;
  logic is_instret_read;
  assign instret_correction = (rs_dest[valid_idx][$clog2(ROB_SIZE)-1:0]
                             - cmu_bcast.rob_head[$clog2(ROB_SIZE)-1:0]);
  assign is_instret_read = (rs_imm[valid_idx][11:0] == `YSYX_CSR_INSTRET_
                         || rs_imm[valid_idx][11:0] == `YSYX_CSR_MINSTRET);

  // CSR read data with instret correction for OoO timing
  logic [XLEN-1:0] csr_rdata_corrected;
  assign csr_rdata_corrected = is_instret_read
    ? (exu_csr.rdata + XLEN'(instret_correction))
    : exu_csr.rdata;

  // { Write back (RS)
  assign exu_rou.dest = rs_dest[valid_idx];
  assign exu_rou.result = (rs_system[valid_idx]
    ? csr_rdata_corrected
    : (rs_alu[valid_idx][5:4] == 2'b01
      ? rs_mul_a[valid_idx]
      : rs_jen[valid_idx]
        ? rs_pc[valid_idx] + (rs_c[valid_idx] ? 2 : 4)
        : alu_result));

  assign exu_rou.npc = (
    (rs_ecall[valid_idx] || rs_ebreak[valid_idx])
    ? csr_bcast.mtvec
    : rs_trap[valid_idx]
      ? csr_bcast.tvec
      : rs_mret[valid_idx]
        ? exu_csr.mepc
        : rs_sret[valid_idx]
          ? exu_csr.sepc
          : (rs_br_jmp[valid_idx]) || (rs_br_cond[valid_idx] && |alu_result)
            ? addr_exu
            : (rs_pc[valid_idx] + (rs_c[valid_idx] ? 2 : 4)));
  assign exu_rou.ebreak = rs_ebreak[valid_idx];
  assign exu_rou.btaken = (rs_br_cond[valid_idx] && |alu_result);

  assign exu_rou.prd = rs_prd[valid_idx];
  assign exu_rou.rd = rs_rd[valid_idx];

  assign exu_rou.inst = rs_inst[valid_idx];
  assign exu_rou.pc = rs_pc[valid_idx];

  assign exu_rou.csr_wen = |rs_csr_csw[valid_idx];
  assign exu_rou.csr_wdata = csr_wdata;
  assign exu_rou.csr_addr = rs_imm[valid_idx][11:0];
  assign exu_rou.ecall = rs_ecall[valid_idx];
  assign exu_rou.mret = rs_mret[valid_idx];
  assign exu_rou.sret = rs_sret[valid_idx];

  assign exu_rou.trap = rs_trap[valid_idx];
  assign exu_rou.tval = rs_tval[valid_idx];
  assign exu_rou.cause = rs_cause[valid_idx];

  // Difftest: CSR reads from TIME/TIMEH/MCYCLE/MCYCLEH need skip
  assign exu_rou.difftest_skip = |rs_csr_csw[valid_idx] && (
      rs_imm[valid_idx][11:0] == `YSYX_CSR_TIME___
    || rs_imm[valid_idx][11:0] == `YSYX_CSR_TIMEH__
    || rs_imm[valid_idx][11:0] == `YSYX_CSR_CYCLE__
    || rs_imm[valid_idx][11:0] == `YSYX_CSR_MCYCLE_
    || rs_imm[valid_idx][11:0] == `YSYX_CSR_MCYCLEH
  );

  assign exu_rou.valid = valid_found;
  // } Write back (RS)

`ifdef YSYX_M_EXTENSION
  // alu for M Extension
  ysyx_exu_mul mul (
      .clock(clock),
      .in_a(rs_vj[mul_rs_idx]),
      .in_b(rs_vk[mul_rs_idx]),
      .in_op(rs_alu[mul_rs_idx]),
      .in_word(rs_word[mul_rs_idx]),
      .in_valid(mul_found
        && !muling
        && rs_mul_ready[mul_rs_idx] == 0
        && rs_pr1[mul_rs_idx] == 0 && rs_pr2[mul_rs_idx] == 0),
      .out_r(reg_wdata_mul),
      .out_valid(mul_valid)
  );
`endif

endmodule

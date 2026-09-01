`include "rapt.svh"
`include "rapt_if.svh"
`include "rapt_rnu_internal_if.svh"
`include "rapt_dpi_c.svh"

// Rename Unit (RNU): pure rename stage.
// Contains:
//   - Rename Queue (RNQ): buffers decoded uops before renaming
//   - Free List: allocates / deallocates physical registers
//   - Map Table: speculative (MAP) + committed (RAT) rename maps
//
// Dual-issue: renames up to 2 instructions per cycle with RAW dependency
// handling between the two rename slots (slot B sees slot A's rename result
// when they share the same architectural register).
module rapt_rnu #(
    parameter unsigned RIQ_SIZE = `RAPT_RIQ_SIZE,
    parameter unsigned RNUM = `RAPT_REG_SIZE,
    parameter unsigned RLEN = `RAPT_REG_LEN,
    parameter unsigned PNUM = `RAPT_PHY_SIZE,
    parameter unsigned PLEN = `RAPT_PHY_LEN,
    /* verilator lint_off UNUSEDPARAM */
    parameter unsigned XLEN = `RAPT_XLEN
    /* verilator lint_on UNUSEDPARAM */
) (
    input clock,

    rou_cmu_if.in   rou_cmu,
    cmu_bcast_if.in cmu_bcast,

    idu_rnu_if.slave  idu_rnu,
    rnu_rou_if.master rnu_rou,

    // Debug: MAP and RAT snapshots for architectural register view
    output [PLEN-1:0] map_snapshot[RNUM],
    output [PLEN-1:0] rat_snapshot[RNUM],

    input reset
);
  // ================================================================
  // Rename Queue (RNQ)
  // ================================================================
  logic [$clog2(RIQ_SIZE)-1:0] rnq_head_a;
  (* keep = "true" *) logic [RIQ_SIZE-1:0] rnq_tail_oh_a;
  logic           [RIQ_SIZE-1:0] rnq_valid;

  (* ram_style = "registers" *) rapt_pkg::uop_t rnq_uops[RIQ_SIZE];
  (* ram_style = "registers" *) logic [RLEN-1:0] rnq_rd[RIQ_SIZE];
  (* ram_style = "registers" *) logic [XLEN-1:0] rnq_op1[RIQ_SIZE];
  (* ram_style = "registers" *) logic [XLEN-1:0] rnq_op2[RIQ_SIZE];
  (* ram_style = "registers" *) logic [RLEN-1:0] rnq_rs1[RIQ_SIZE];
  (* ram_style = "registers" *) logic [RLEN-1:0] rnq_rs2[RIQ_SIZE];

  // ================================================================
  // Rename Pipeline Registers (2-sub-stage rename)
  // Stage 1: Read maptable + freelist allocate (combinational)
  // Stage 2: Present registered results to ROU
  // ================================================================
  // Slot A
  logic                          rn_pipe_valid_a;
  rapt_pkg::uop_t                rn_pipe_uop_a;
  logic [PLEN-1:0] rn_pipe_pr1_a, rn_pipe_pr2_a, rn_pipe_prd_a, rn_pipe_prs_a;
  logic [XLEN-1:0] rn_pipe_op1_a, rn_pipe_op2_a;

`ifdef RAPT_DUAL_ISSUE
  // Slot B
  logic rn_pipe_valid_b;
  rapt_pkg::uop_t rn_pipe_uop_b;
  logic [PLEN-1:0] rn_pipe_pr1_b, rn_pipe_pr2_b, rn_pipe_prd_b, rn_pipe_prs_b;
  logic [XLEN-1:0] rn_pipe_op1_b, rn_pipe_op2_b;
`endif
  // Second RNQ enqueue (when IDU provides 2 instructions)
  logic [$clog2(RIQ_SIZE)-1:0] rnq_head_b;

  // Stage 1 fires when RNQ has entry AND pipeline register is free (or being consumed)
  logic rn_pipe_ready_a;
  assign rn_pipe_ready_a = !rn_pipe_valid_a || rnu_rou.ready;

  rapt_pkg::uop_t rnq_tail_uop_a;
  logic [RLEN-1:0] rnq_tail_rd_a, rnq_tail_rs1_a, rnq_tail_rs2_a;
  logic [XLEN-1:0] rnq_tail_op1_a, rnq_tail_op2_a;
  logic rnq_tail_valid_a;
  logic rnq_enq_fire_a, rnq_deq_fire_a;

`ifdef RAPT_DUAL_ISSUE
  logic [RIQ_SIZE-1:0] rnq_tail_oh_b;
  rapt_pkg::uop_t rnq_tail_uop_b;
  logic [RLEN-1:0] rnq_tail_rd_b, rnq_tail_rs1_b, rnq_tail_rs2_b;
  logic [XLEN-1:0] rnq_tail_op1_b, rnq_tail_op2_b;
  logic rnq_tail_valid_b, rnq_tail_is_pair_b;
  assign rnq_tail_oh_b = {rnq_tail_oh_a[RIQ_SIZE-2:0], rnq_tail_oh_a[RIQ_SIZE-1]};

  // Second RNQ dequeue: can dequeue slot B if slot A fires, next entry valid,
  // is actually a dual-pair B-slot, and freelist has enough registers.
  logic [RIQ_SIZE-1:0] rnq_is_pair;
  logic rnq_deq_fire_b;
  assign rnq_deq_fire_b = rnq_deq_fire_a && rnq_tail_is_pair_b
      && rnq_tail_valid_b
      && (rnq_tail_rd_b == 0 || !fl_bus.alloc_empty_b);

  assign rnq_head_b = rnq_head_a + 1;
  logic rnq_enq_fire_b;
  assign rnq_enq_fire_b = idu_rnu.valid_b && rnq_enq_fire_a && !rnq_valid[rnq_head_b];
`endif

  always_comb begin
    rnq_tail_uop_a = '0;
    rnq_tail_rd_a = '0;
    rnq_tail_rs1_a = '0;
    rnq_tail_rs2_a = '0;
    rnq_tail_op1_a = '0;
    rnq_tail_op2_a = '0;
    rnq_tail_valid_a = 1'b0;
`ifdef RAPT_DUAL_ISSUE
    rnq_tail_uop_b = '0;
    rnq_tail_rd_b = '0;
    rnq_tail_rs1_b = '0;
    rnq_tail_rs2_b = '0;
    rnq_tail_op1_b = '0;
    rnq_tail_op2_b = '0;
    rnq_tail_valid_b = 1'b0;
    rnq_tail_is_pair_b = 1'b0;
`endif
    for (int i = 0; i < RIQ_SIZE; i++) begin
      if (rnq_tail_oh_a[i]) begin
        rnq_tail_uop_a = rnq_uops[i];
        rnq_tail_rd_a = rnq_rd[i];
        rnq_tail_rs1_a = rnq_rs1[i];
        rnq_tail_rs2_a = rnq_rs2[i];
        rnq_tail_op1_a = rnq_op1[i];
        rnq_tail_op2_a = rnq_op2[i];
        rnq_tail_valid_a = rnq_valid[i];
      end
`ifdef RAPT_DUAL_ISSUE
      if (rnq_tail_oh_b[i]) begin
        rnq_tail_uop_b = rnq_uops[i];
        rnq_tail_rd_b = rnq_rd[i];
        rnq_tail_rs1_b = rnq_rs1[i];
        rnq_tail_rs2_b = rnq_rs2[i];
        rnq_tail_op1_b = rnq_op1[i];
        rnq_tail_op2_b = rnq_op2[i];
        rnq_tail_valid_b = rnq_valid[i];
        rnq_tail_is_pair_b = rnq_is_pair[i];
      end
`endif
    end
  end

`ifdef RAPT_DUAL_ISSUE
  // When valid_b is set, both RNQ slots must be free to enqueue.
  // This prevents slot A from enqueuing without slot B, avoiding duplication.
  assign rnq_enq_fire_a = idu_rnu.valid_a && !rnq_valid[rnq_head_a]
      && (!idu_rnu.valid_b || !rnq_valid[rnq_head_b]);
`else
  assign rnq_enq_fire_a = idu_rnu.valid_a && !rnq_valid[rnq_head_a];
`endif
  assign rnq_deq_fire_a = rn_pipe_ready_a && rnq_tail_valid_a;

  // Output uses pipeline register (stage 2)
  assign rnu_rou.valid_a = rn_pipe_valid_a;
`ifdef RAPT_DUAL_ISSUE
  // When IDU sends valid_b, RNQ must have room for both entries.
  // If only head is free but head_b isn't, reject to avoid dropping slot B.
  assign idu_rnu.ready = !rnq_valid[rnq_head_a] && (!idu_rnu.valid_b || !rnq_valid[rnq_head_b]);
`else
  assign idu_rnu.ready = !rnq_valid[rnq_head_a];
`endif

`ifdef RAPT_DUAL_ISSUE
  assign rnu_rou.valid_b = rn_pipe_valid_b;
`endif

  // ================================================================
  // Dual-issue rename dependency detection (combinational)
  // Slot B must see slot A's rename result when they share arch registers.
  // ================================================================
`ifdef RAPT_DUAL_ISSUE
  logic slot_a_writes_rd;
  assign slot_a_writes_rd = rnq_deq_fire_a && (rnq_tail_rd_a != 0);

  // RAW bypass: slot B's source registers match slot A's destination
  logic dep_b_rs1_from_a;
  logic dep_b_rs2_from_a;
  logic dep_b_rdold_from_a;
  assign dep_b_rs1_from_a   = slot_a_writes_rd && (rnq_tail_rs1_b == rnq_tail_rd_a);
  assign dep_b_rs2_from_a   = slot_a_writes_rd && (rnq_tail_rs2_b == rnq_tail_rd_a);
  assign dep_b_rdold_from_a = slot_a_writes_rd && (rnq_tail_rd_b == rnq_tail_rd_a);
`endif

  always_ff @(posedge clock) begin
    if (reset || cmu_bcast.flush_pipe) begin
      rnq_head_a <= '0;
      rnq_tail_oh_a <= {{RIQ_SIZE-1{1'b0}}, 1'b1};
      rnq_valid <= '0;
      rn_pipe_valid_a <= 1'b0;
`ifdef RAPT_DUAL_ISSUE
      rn_pipe_valid_b <= 1'b0;
      rnq_is_pair <= '0;
`endif
      // RNQ payload arrays (uops/rd/op*/rs*) are intentionally NOT reset:
      // every read is gated by rnq_valid[] (dequeue-side reads index
      // rnq_tail_* whose valid was checked), so the data flops are
      // don't-care (same principle as rapt_prf).  This removes
      // ~RIQ_SIZE*uop_width endpoints from the reset/flush network.
    end else begin
      // One static write cone per RNQ entry. Preserve the former NBA
      // priority: dequeue wins over enqueue on any selector alias.
      for (int i = 0; i < RIQ_SIZE; i++) begin
`ifdef RAPT_DUAL_ISSUE
        if (rnq_deq_fire_b && rnq_tail_oh_b[i]) begin
          rnq_valid[i]   <= 1'b0;
          rnq_is_pair[i] <= 1'b0;
        end else if (rnq_deq_fire_a && rnq_tail_oh_a[i]) begin
          rnq_valid[i]   <= 1'b0;
          rnq_is_pair[i] <= 1'b0;
        end else if (rnq_enq_fire_b && i == int'(rnq_head_b)) begin
          rnq_valid[i]   <= 1'b1;
          rnq_uops[i]    <= idu_rnu.uop_b;
          rnq_rd[i]      <= idu_rnu.uop_b.rd;
          rnq_op1[i]     <= idu_rnu.op1_b;
          rnq_op2[i]     <= idu_rnu.op2_b;
          rnq_rs1[i]     <= idu_rnu.rs1_b;
          rnq_rs2[i]     <= idu_rnu.rs2_b;
          rnq_is_pair[i] <= 1'b1;
        end else if (rnq_enq_fire_a && i == int'(rnq_head_a)) begin
          rnq_valid[i]   <= 1'b1;
          rnq_uops[i]    <= idu_rnu.uop_a;
          rnq_rd[i]      <= idu_rnu.uop_a.rd;
          rnq_op1[i]     <= idu_rnu.op1_a;
          rnq_op2[i]     <= idu_rnu.op2_a;
          rnq_rs1[i]     <= idu_rnu.rs1_a;
          rnq_rs2[i]     <= idu_rnu.rs2_a;
          rnq_is_pair[i] <= 1'b0;
        end
`else
        if (rnq_deq_fire_a && rnq_tail_oh_a[i]) begin
          rnq_valid[i] <= 1'b0;
        end else if (rnq_enq_fire_a && i == int'(rnq_head_a)) begin
          rnq_valid[i] <= 1'b1;
          rnq_uops[i]  <= idu_rnu.uop_a;
          rnq_rd[i]    <= idu_rnu.uop_a.rd;
          rnq_op1[i]   <= idu_rnu.op1_a;
          rnq_op2[i]   <= idu_rnu.op2_a;
          rnq_rs1[i]   <= idu_rnu.rs1_a;
          rnq_rs2[i]   <= idu_rnu.rs2_a;
        end
`endif
      end

      // ---- RNQ Enqueue pointer ----
      if (rnq_enq_fire_a) begin
`ifdef RAPT_DUAL_ISSUE
        if (rnq_enq_fire_b) begin
          rnq_head_a <= rnq_head_a + 2;
        end else begin
          rnq_head_a <= rnq_head_a + 1;
        end
`else
        rnq_head_a <= rnq_head_a + 1;
`endif
      end

      // ---- RNQ Dequeue + Rename Stage 1 -> Stage 2 ----
      if (rnq_deq_fire_a) begin
        // Slot A: register rename results
        rn_pipe_valid_a <= 1'b1;
        rn_pipe_uop_a <= rnq_tail_uop_a;
        rn_pipe_op1_a <= rnq_tail_op1_a;
        rn_pipe_op2_a <= rnq_tail_op2_a;
        rn_pipe_pr1_a <= mt_bus.map_rdata_a;
        rn_pipe_pr2_a <= mt_bus.map_rdata_b;
        rn_pipe_prd_a <= (rnq_tail_rd_a != 0) ? fl_bus.alloc_pr_a : '0;
        rn_pipe_prs_a <= mt_bus.map_rdata_c;

`ifdef RAPT_DUAL_ISSUE
        if (rnq_deq_fire_b) begin
          rnq_tail_oh_a <= {rnq_tail_oh_a[RIQ_SIZE-3:0], rnq_tail_oh_a[RIQ_SIZE-1:RIQ_SIZE-2]};

          // Slot B: rename with RAW dependency bypass from slot A
          rn_pipe_valid_b <= 1'b1;
          rn_pipe_uop_b <= rnq_tail_uop_b;
          rn_pipe_op1_b <= rnq_tail_op1_b;
          rn_pipe_op2_b <= rnq_tail_op2_b;
          // rs1_b: bypass from slot A if dependency
          rn_pipe_pr1_b <= dep_b_rs1_from_a ? fl_bus.alloc_pr_a : mt_bus.map_rdata_d;
          // rs2_b: bypass from slot A if dependency
          rn_pipe_pr2_b <= dep_b_rs2_from_a ? fl_bus.alloc_pr_a : mt_bus.map_rdata_e;
          // prd_b: new physical register from freelist slot B
          rn_pipe_prd_b <= (rnq_tail_rd_b != 0) ? fl_bus.alloc_pr_b : '0;
          // prs_b: old mapping: bypass from slot A if same rd
          rn_pipe_prs_b <= dep_b_rdold_from_a ? fl_bus.alloc_pr_a : mt_bus.map_rdata_f;
        end else begin
          rnq_tail_oh_a <= rnq_tail_oh_b;
          rn_pipe_valid_b <= 1'b0;
        end
`else
        rnq_tail_oh_a <= {rnq_tail_oh_a[RIQ_SIZE-2:0], rnq_tail_oh_a[RIQ_SIZE-1]};
`endif
      end else if (rnu_rou.ready) begin
        rn_pipe_valid_a <= 1'b0;
`ifdef RAPT_DUAL_ISSUE
        rn_pipe_valid_b <= 1'b0;
`endif
      end
    end
  end

  // RNQ read-side outputs (stage 2: from pipeline register)
  assign rnu_rou.uop_a = rn_pipe_uop_a;
  assign rnu_rou.op1_a = rn_pipe_op1_a;
  assign rnu_rou.op2_a = rn_pipe_op2_a;

  // ================================================================
  // Commit signals (shared by freelist, maptable, PRF)
  // ================================================================
  logic commit_dealloc;
  assign commit_dealloc = rou_cmu.valid_a && rou_cmu.rd_a != 0;

  logic commit_dealloc_b;
  assign commit_dealloc_b = rou_cmu.valid_b && rou_cmu.rd_b != 0;

  // ================================================================
  // Internal interface instances
  // ================================================================
  rnu_fl_if fl_bus ();  // RNU <-> Free List
  rnu_mt_if mt_bus ();  // RNU <-> Map Table

  // ================================================================
  // Free List - interface drive
  // ================================================================
  assign fl_bus.flush_pipe  = cmu_bcast.flush_pipe;
  assign fl_bus.flush_rd_a  = cmu_bcast.rd_a;
  assign fl_bus.flush_rd_b  = cmu_bcast.valid_b ? cmu_bcast.rd_b : '0;
  assign fl_bus.alloc_req_a = rnq_deq_fire_a && !fl_bus.alloc_empty_a && rnq_tail_rd_a != 0;
`ifdef RAPT_DUAL_ISSUE
  assign fl_bus.alloc_req_b = rnq_deq_fire_b && !fl_bus.alloc_empty_b && rnq_tail_rd_b != 0;
`endif
  assign fl_bus.dealloc_req_a = commit_dealloc;
  assign fl_bus.dealloc_pr_a  = rou_cmu.prs_a;
  assign fl_bus.dealloc_req_b = commit_dealloc_b;
  assign fl_bus.dealloc_pr_b  = rou_cmu.prs_b;

  rapt_rnu_freelist #(
      .RNUM(RNUM),
      .PNUM(PNUM),
      .PLEN(PLEN),
      .RLEN(RLEN)
  ) u_freelist (
      .clock(clock),
      .reset(reset),
      .fl   (fl_bus)
  );

  // ================================================================
  // Map Table - interface drive
  // ================================================================
  assign mt_bus.flush_pipe  = cmu_bcast.flush_pipe;
  // Speculative write A (on allocation)
  assign mt_bus.map_wen_a   = fl_bus.alloc_req_a;
  assign mt_bus.map_waddr_a = rnq_tail_rd_a;
  assign mt_bus.map_wdata_a = fl_bus.alloc_pr_a;
  // Speculative read: rs1, rs2
  assign mt_bus.map_raddr_a = rnq_tail_rs1_a;
  assign mt_bus.map_raddr_b = rnq_tail_rs2_a;
  // Speculative read: rd old mapping (prs for ROB dealloc)
  assign mt_bus.map_raddr_c = rnq_tail_rd_a;

`ifdef RAPT_DUAL_ISSUE
  // Speculative write B (slot B allocation: younger, wins on conflict)
  assign mt_bus.map_wen_b   = fl_bus.alloc_req_b;
  assign mt_bus.map_waddr_b = rnq_tail_rd_b;
  assign mt_bus.map_wdata_b = fl_bus.alloc_pr_b;
  // Speculative read slot B: rs1_b, rs2_b, rd_old_b
  assign mt_bus.map_raddr_d = rnq_tail_rs1_b;
  assign mt_bus.map_raddr_e = rnq_tail_rs2_b;
  assign mt_bus.map_raddr_f = rnq_tail_rd_b;
`endif

  // Committed write A
  assign mt_bus.rat_wen_a   = commit_dealloc;
  assign mt_bus.rat_waddr_a = rou_cmu.rd_a;
  assign mt_bus.rat_wdata_a = rou_cmu.prd_a;
  // Committed write B (dual commit)
  assign mt_bus.rat_wen_b   = commit_dealloc_b;
  assign mt_bus.rat_waddr_b = rou_cmu.rd_b;
  assign mt_bus.rat_wdata_b = rou_cmu.prd_b;

  logic [PLEN-1:0] mt_rat_snapshot[RNUM];
  logic [PLEN-1:0] mt_map_snapshot[RNUM];

  rapt_rnu_maptable #(
      .RNUM(RNUM),
      .PLEN(PLEN)
  ) u_maptable (
      .clock       (clock),
      .reset       (reset),
      .mt          (mt_bus),
      .map_snapshot(mt_map_snapshot),
      .rat_snapshot(mt_rat_snapshot)
  );

  // Expose snapshots to top level
  genvar gi;
  generate
    for (gi = 0; gi < RNUM; gi = gi + 1) begin : gen_snapshot_out
      assign map_snapshot[gi] = mt_map_snapshot[gi];
      assign rat_snapshot[gi] = mt_rat_snapshot[gi];
    end
  endgenerate

  // ================================================================
  // Register Renaming outputs (stage 2: from pipeline register)
  // ================================================================
  assign rnu_rou.pr1_a = rn_pipe_pr1_a;
  assign rnu_rou.pr2_a = rn_pipe_pr2_a;
  assign rnu_rou.prd_a = rn_pipe_prd_a;
  // prs = old physical mapping for rd (before rename), needed by ROB for dealloc
  assign rnu_rou.prs_a = rn_pipe_prs_a;

`ifdef RAPT_DUAL_ISSUE
  assign rnu_rou.uop_b = rn_pipe_uop_b;
  assign rnu_rou.op1_b = rn_pipe_op1_b;
  assign rnu_rou.op2_b = rn_pipe_op2_b;
  assign rnu_rou.pr1_b = rn_pipe_pr1_b;
  assign rnu_rou.pr2_b = rn_pipe_pr2_b;
  assign rnu_rou.prd_b = rn_pipe_prd_b;
  assign rnu_rou.prs_b = rn_pipe_prs_b;
`endif

endmodule

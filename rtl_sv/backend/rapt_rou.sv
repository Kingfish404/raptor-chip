`include "rapt.svh"
`include "rapt_if.svh"
`include "rapt_soc.svh"

// Re-Order Unit (ROU) - dispatch queue + reorder buffer + commit.
//
// Sub-sections:
//   1. Dispatch Queue (UOQ)  - buffers renamed uops before ROB insertion
//   2. Reorder Buffer (ROB)  - tracks in-flight instructions for in-order commit
//   3. Operand Bypass         - forwards results from EXU/IOQ to dispatch
//   4. Commit Logic           - retires ROB head when ready
//
// Parameters sized for single-issue; ISSUE_WIDTH controls dispatch/commit width.
module rapt_rou #(
    parameter unsigned IIQ_SIZE = `RAPT_IIQ_SIZE,
    parameter unsigned ROB_SIZE = `RAPT_ROB_SIZE,
    /* verilator lint_off UNUSEDPARAM */
    parameter unsigned RNUM = `RAPT_REG_SIZE,
    parameter unsigned RLEN = `RAPT_REG_LEN,
    /* verilator lint_on UNUSEDPARAM */
    parameter unsigned PLEN = `RAPT_PHY_LEN,
    parameter unsigned XLEN = `RAPT_XLEN
) (
    input clock,

    rnu_rou_if.slave rnu_rou,

    exu_prf_if.master exu_prf,
    rou_exu_if.master rou_exu,

    exu_rou_if.in exu_rou,
    exu_rou_b_if.in exu_rou_b,
    exu_rou_c_if.in exu_rou_c,
    exu_ioq_bcast_if.in exu_ioq_bcast,

    // interrupt
    csr_bcast_if.in csr_bcast,
    // Async trap inputs: timer, software, external, and S-mode delegated
    input clint_timer_trap,
    input clint_sw_trap,
    input clint_ext_trap,

    // S-mode delegated interrupt (level): cause is supplied by csr.
    input                  s_int_pending,
    input [`RAPT_XLEN-1:0] s_int_cause,

    // commit
    rou_cmu_if.out rou_cmu,
    rou_csr_if.out rou_csr,
    rou_lsu_if.out rou_lsu,

    // Dispatch-only uop payload snapshot (cold side-channel for RS issue-read
    // and ioq trap-inst display). Indexed by ROB destination.
    output rapt_pkg::uop_payload_t uop_pl[`RAPT_ROB_SIZE],

    // RISC-V Debug: external halt request from the cluster Debug Module.
    // When asserted (level), block UOQ->ROB dispatch so the in-flight ROB
    // drains naturally; once `rob_empty` we report `halted_o` to the DM.
    // Resume happens automatically when `dm_haltreq_i` is deasserted.
    input  logic            dm_haltreq_i,
    output logic            halted_o,
    // Next architectural PC at the halt boundary (= npc of the youngest
    // committed instruction, or PC_RESET on cold halt). The DM samples
    // this on the halted_o rising edge and uses it as dpc.
    output logic [XLEN-1:0] halt_pc_o,
    // Single-cycle pulse: at least one ROB entry retired this cycle
    // (commit fire). Used by the DM to count instructions while
    // dcsr.step=1 so single-step requests halt after exactly one retire.
    output logic            commit_fire_o,

    input reset
);
  // ready_a is consumed by the testbench (--public) for hazard observation,
  // and only by RTL when !RAPT_DUAL_ISSUE; mark it as intentionally unused
  // by the synthesis tool.
  /* verilator lint_off UNUSEDSIGNAL */
  logic valid_a, ready_a;
  /* verilator lint_on UNUSEDSIGNAL */
  logic            flush_pipe;
  logic            fence_time;

  // Async trap state
  logic            recieved_trap;
  logic            recieved_sw_trap  /* verilator public */;
  logic [XLEN-1:0] trap_pc;
  logic [XLEN-1:0] trap_cause  /* verilator public */;

  // Forward declarations (used across sections)
  logic [$clog2(ROB_SIZE)-1:0] rob_head, rob_tail_a;
  rapt_pkg::rob_entry_t rob_entry[ROB_SIZE];
  logic head0_br_p_fail;
  logic head0_valid;

  logic dual_commit;

  // ================================================================
  // 4. Commit Logic: dual commit (up to 2 per cycle)
  // ================================================================
  // Aliases for ROB head entries
  wire [$clog2(ROB_SIZE)-1:0] h0 = rob_head;
  wire [$clog2(ROB_SIZE)-1:0] h1 = rob_head + 1;

  // ================================================================
  // 1. Dispatch Queue (UOQ)
  // ================================================================
  logic [$clog2(IIQ_SIZE)-1:0] uoq_head_a, uoq_tail_a;
  logic           [IIQ_SIZE-1:0] uoq_valid;

  rapt_pkg::uop_t                uoq_uops      [IIQ_SIZE];
  logic           [    PLEN-1:0] uoq_pr1       [IIQ_SIZE];
  logic           [    PLEN-1:0] uoq_pr2       [IIQ_SIZE];
  logic           [    PLEN-1:0] uoq_prd       [IIQ_SIZE];
  logic           [    PLEN-1:0] uoq_prs       [IIQ_SIZE];
  logic           [    XLEN-1:0] uoq_op1       [IIQ_SIZE];
  logic           [    XLEN-1:0] uoq_op2       [IIQ_SIZE];

  // PRF pre-read: latched at enqueue, updated by broadcast forwarding
  logic           [    XLEN-1:0] uoq_pv1       [IIQ_SIZE];
  logic           [    XLEN-1:0] uoq_pv2       [IIQ_SIZE];
  logic           [IIQ_SIZE-1:0] uoq_pv1_valid;
  logic           [IIQ_SIZE-1:0] uoq_pv2_valid;

  logic uoq_enq_fire_a, uoq_deq_fire_a;
  logic sys_resume;
`ifdef RAPT_DUAL_ISSUE
  // Dual-issue UOQ pointers
  logic [$clog2(IIQ_SIZE)-1:0] uoq_head_b, uoq_tail_b;

  // Lightweight resume for pure CSR: no flush, just unblock IFU and clear drain

  assign uoq_head_b = uoq_head_a + 1;
  assign uoq_tail_b = uoq_tail_a + 1;

  // When valid_b is set, both UOQ slots must be free to enqueue.
  // This prevents slot A from enqueuing without slot B, avoiding duplication.
  assign uoq_enq_fire_a  = rnu_rou.valid_a && !uoq_valid[uoq_head_a]
      && (!rnu_rou.valid_b || !uoq_valid[uoq_head_b]);
`else
  assign uoq_enq_fire_a = rnu_rou.valid_a && !uoq_valid[uoq_head_a];
`endif

  // Pipeline drain: serializing instructions (CSR/fence/ecall/mret/sret)
  // must wait for ROB to empty before dispatch, and block subsequent dispatch
  // until committed. This eliminates OoO timing hacks (e.g. instret correction).
  logic uoq_tail_a_is_serializing;
  assign uoq_tail_a_is_serializing = uoq_valid[uoq_tail_a] && (
      uoq_uops[uoq_tail_a].system
      || uoq_uops[uoq_tail_a].f_i
      || uoq_uops[uoq_tail_a].f_time);

  logic rob_empty;
  assign rob_empty = (rob_head == rob_tail_a) && !rob_entry[rob_head].busy;

  // External halt: drain ROB and stop dispatching new uops while haltreq is
  // asserted. `halted_o` is the level the DM samples for dmstatus.allhalted.
  assign halted_o  = dm_haltreq_i && rob_empty;

  // Latched npc of the youngest committed instruction. Used as the resume
  // PC reported to the Debug Module (dpc). Reset to PC_RESET so a halt
  // before any commit shows the cold-boot vector instead of 0.
  logic [XLEN-1:0] commit_npc_q;
  always_ff @(posedge clock) begin
    if (reset) begin
      commit_npc_q <= XLEN'(`RAPT_PC_INIT);
    end else if (head0_valid && !recieved_trap) begin
      commit_npc_q <= dual_commit ? rob_entry[h1].npc : rob_entry[h0].npc;
    end
  end
  assign halt_pc_o = commit_npc_q;

  // Per-cycle commit-fire pulse for the Debug Module's single-step
  // counter. Asserted iff at least one instruction commits this cycle
  // (matches `head0_valid && !recieved_trap`, mirroring the rob_head
  // increment logic in the always_ff block).
  assign commit_fire_o = head0_valid && !recieved_trap;

  logic serialize_in_flight;

  assign uoq_deq_fire_a = rou_exu.ready && uoq_valid[uoq_tail_a] && !rob_entry[rob_tail_a].busy
      && !serialize_in_flight
      && !dm_haltreq_i
      && (!uoq_tail_a_is_serializing || rob_empty);

`ifdef RAPT_DUAL_ISSUE
  logic uoq_enq_fire_b, uoq_deq_fire_b;
  assign uoq_enq_fire_b = uoq_enq_fire_a && rnu_rou.valid_b && !uoq_valid[uoq_head_b];

  // Track which UOQ entries are B-slots of a dual-issue pair.
  // Prevents consecutive single-issue entries from being treated as a pair.
  logic [IIQ_SIZE-1:0] uoq_is_pair;

  // ROB tail+1 must also be free for dual dispatch
  logic [$clog2(ROB_SIZE)-1:0] rob_tail_b;
  assign rob_tail_b = rob_tail_a + 1;
  assign uoq_deq_fire_b = uoq_deq_fire_a && uoq_is_pair[uoq_tail_b]
      && uoq_valid[uoq_tail_b]
      && !rob_entry[rob_tail_b].busy
      && rou_exu.ready_b;
`endif

  assign valid_a         = uoq_valid[uoq_tail_a] && !rob_entry[rob_tail_a].busy
      && !serialize_in_flight
      && !dm_haltreq_i
      && (!uoq_tail_a_is_serializing || rob_empty);
  assign ready_a = !uoq_valid[uoq_head_a];
  assign rou_exu.valid = valid_a;
`ifdef RAPT_DUAL_ISSUE
  // When RNU sends a dual pair (valid_b), both UOQ slots must be free.
  assign rnu_rou.ready = !uoq_valid[uoq_head_a] && (!rnu_rou.valid_b || !uoq_valid[uoq_head_b]);
`else
  assign rnu_rou.ready = ready_a;
`endif

`ifdef RAPT_DUAL_ISSUE
  assign rou_exu.valid_b = uoq_deq_fire_a && uoq_is_pair[uoq_tail_b]
      && uoq_valid[uoq_tail_b]
      && !rob_entry[rob_tail_b].busy;
`endif

  always_ff @(posedge clock) begin
    if (reset || flush_pipe) begin
      uoq_head_a          <= '0;
      uoq_tail_a          <= '0;
      uoq_valid           <= '0;
      uoq_pv1_valid       <= '0;
      uoq_pv2_valid       <= '0;
      serialize_in_flight <= 1'b0;
`ifdef RAPT_DUAL_ISSUE
      uoq_is_pair <= '0;
`endif
    end else if (sys_resume) begin
      // Pipeline already drained; just clear the serialize lock
      serialize_in_flight <= 1'b0;
    end else begin
      if (uoq_enq_fire_a) begin
        uoq_valid[uoq_head_a] <= 1'b1;
        uoq_uops[uoq_head_a]  <= rnu_rou.uop_a;
        uoq_pr1[uoq_head_a]   <= rnu_rou.pr1_a;
        uoq_pr2[uoq_head_a]   <= rnu_rou.pr2_a;
        uoq_prd[uoq_head_a]   <= rnu_rou.prd_a;
        uoq_prs[uoq_head_a]   <= rnu_rou.prs_a;
        uoq_op1[uoq_head_a]   <= rnu_rou.op1_a;
        uoq_op2[uoq_head_a]   <= rnu_rou.op2_a;

        // PRF pre-read with same-cycle bypass at enqueue
        if (|rnu_rou.pr1_a && exu_rou.valid && exu_rou.prd == rnu_rou.pr1_a) begin
          uoq_pv1[uoq_head_a]       <= exu_rou.result;
          uoq_pv1_valid[uoq_head_a] <= 1'b1;
        end else if (|rnu_rou.pr1_a && exu_rou_b.valid && exu_rou_b.prd == rnu_rou.pr1_a) begin
          uoq_pv1[uoq_head_a]       <= exu_rou_b.result;
          uoq_pv1_valid[uoq_head_a] <= 1'b1;
        end else if (|rnu_rou.pr1_a
          && exu_ioq_bcast.valid && exu_ioq_bcast.prd == rnu_rou.pr1_a) begin
          uoq_pv1[uoq_head_a]       <= exu_ioq_bcast.result;
          uoq_pv1_valid[uoq_head_a] <= 1'b1;
        end else begin
          uoq_pv1[uoq_head_a]       <= exu_prf.pv1_a;
          uoq_pv1_valid[uoq_head_a] <= exu_prf.pv1_a_valid;
        end

        if (|rnu_rou.pr2_a && exu_rou.valid && exu_rou.prd == rnu_rou.pr2_a) begin
          uoq_pv2[uoq_head_a]       <= exu_rou.result;
          uoq_pv2_valid[uoq_head_a] <= 1'b1;
        end else if (|rnu_rou.pr2_a && exu_rou_b.valid && exu_rou_b.prd == rnu_rou.pr2_a) begin
          uoq_pv2[uoq_head_a]       <= exu_rou_b.result;
          uoq_pv2_valid[uoq_head_a] <= 1'b1;
        end else if (|rnu_rou.pr2_a
          && exu_ioq_bcast.valid && exu_ioq_bcast.prd == rnu_rou.pr2_a) begin
          uoq_pv2[uoq_head_a]       <= exu_ioq_bcast.result;
          uoq_pv2_valid[uoq_head_a] <= 1'b1;
        end else begin
          uoq_pv2[uoq_head_a]       <= exu_prf.pv2_a;
          uoq_pv2_valid[uoq_head_a] <= exu_prf.pv2_a_valid;
        end

`ifdef RAPT_DUAL_ISSUE
        if (uoq_enq_fire_b) begin
          uoq_is_pair[uoq_head_a] <= 1'b0;
          uoq_is_pair[uoq_head_b] <= 1'b1;
          uoq_valid[uoq_head_b] <= 1'b1;
          uoq_uops[uoq_head_b] <= rnu_rou.uop_b;
          uoq_pr1[uoq_head_b] <= rnu_rou.pr1_b;
          uoq_pr2[uoq_head_b] <= rnu_rou.pr2_b;
          uoq_prd[uoq_head_b] <= rnu_rou.prd_b;
          uoq_prs[uoq_head_b] <= rnu_rou.prs_b;
          uoq_op1[uoq_head_b] <= rnu_rou.op1_b;
          uoq_op2[uoq_head_b] <= rnu_rou.op2_b;

          // PRF pre-read for slot B
          if (|rnu_rou.pr1_b && exu_rou.valid && exu_rou.prd == rnu_rou.pr1_b) begin
            uoq_pv1[uoq_head_b]       <= exu_rou.result;
            uoq_pv1_valid[uoq_head_b] <= 1'b1;
          end else if (|rnu_rou.pr1_b && exu_rou_b.valid && exu_rou_b.prd == rnu_rou.pr1_b) begin
            uoq_pv1[uoq_head_b]       <= exu_rou_b.result;
            uoq_pv1_valid[uoq_head_b] <= 1'b1;
          end else if (|rnu_rou.pr1_b
            && exu_ioq_bcast.valid && exu_ioq_bcast.prd == rnu_rou.pr1_b) begin
            uoq_pv1[uoq_head_b]       <= exu_ioq_bcast.result;
            uoq_pv1_valid[uoq_head_b] <= 1'b1;
          end else begin
            uoq_pv1[uoq_head_b]       <= exu_prf.pv1_b;
            uoq_pv1_valid[uoq_head_b] <= exu_prf.pv1_b_valid;
          end

          if (|rnu_rou.pr2_b && exu_rou.valid && exu_rou.prd == rnu_rou.pr2_b) begin
            uoq_pv2[uoq_head_b]       <= exu_rou.result;
            uoq_pv2_valid[uoq_head_b] <= 1'b1;
          end else if (|rnu_rou.pr2_b && exu_rou_b.valid && exu_rou_b.prd == rnu_rou.pr2_b) begin
            uoq_pv2[uoq_head_b]       <= exu_rou_b.result;
            uoq_pv2_valid[uoq_head_b] <= 1'b1;
          end else if (|rnu_rou.pr2_b
            && exu_ioq_bcast.valid && exu_ioq_bcast.prd == rnu_rou.pr2_b) begin
            uoq_pv2[uoq_head_b]       <= exu_ioq_bcast.result;
            uoq_pv2_valid[uoq_head_b] <= 1'b1;
          end else begin
            uoq_pv2[uoq_head_b]       <= exu_prf.pv2_b;
            uoq_pv2_valid[uoq_head_b] <= exu_prf.pv2_b_valid;
          end

          uoq_head_a <= uoq_head_a + 2;
        end else begin
          uoq_is_pair[uoq_head_a] <= 1'b0;
          uoq_head_a <= uoq_head_a + 1;
        end
`else
        uoq_head_a <= uoq_head_a + 1;
`endif
      end
      if (uoq_deq_fire_a) begin
        // Track serializing instruction dispatch for pipeline drain
        if (uoq_tail_a_is_serializing) begin
          serialize_in_flight <= 1'b1;
        end
`ifdef RAPT_DUAL_ISSUE
        if (uoq_deq_fire_b) begin
          uoq_tail_a <= uoq_tail_a + 2;
          uoq_valid[uoq_tail_a] <= 1'b0;
          uoq_valid[uoq_tail_b] <= 1'b0;
          uoq_is_pair[uoq_tail_b] <= 1'b0;
        end else begin
          uoq_tail_a              <= uoq_tail_a + 1;
          uoq_valid[uoq_tail_a]   <= 1'b0;
          uoq_is_pair[uoq_tail_a] <= 1'b0;
        end
`else
        uoq_tail_a            <= uoq_tail_a + 1;
        uoq_valid[uoq_tail_a] <= 1'b0;
`endif
      end

      // Broadcast forwarding: update pre-read values during UOQ residence
      for (int i = 0; i < IIQ_SIZE; i++) begin
        if (uoq_valid[i]) begin
          if (|uoq_pr1[i] && !uoq_pv1_valid[i]) begin
            if (exu_rou.valid && exu_rou.prd == uoq_pr1[i]) begin
              uoq_pv1[i]       <= exu_rou.result;
              uoq_pv1_valid[i] <= 1'b1;
            end else if (exu_rou_b.valid && exu_rou_b.prd == uoq_pr1[i]) begin
              uoq_pv1[i]       <= exu_rou_b.result;
              uoq_pv1_valid[i] <= 1'b1;
            end else if (exu_ioq_bcast.valid && exu_ioq_bcast.prd == uoq_pr1[i]) begin
              uoq_pv1[i]       <= exu_ioq_bcast.result;
              uoq_pv1_valid[i] <= 1'b1;
            end
          end
          if (|uoq_pr2[i] && !uoq_pv2_valid[i]) begin
            if (exu_rou.valid && exu_rou.prd == uoq_pr2[i]) begin
              uoq_pv2[i]       <= exu_rou.result;
              uoq_pv2_valid[i] <= 1'b1;
            end else if (exu_rou_b.valid && exu_rou_b.prd == uoq_pr2[i]) begin
              uoq_pv2[i]       <= exu_rou_b.result;
              uoq_pv2_valid[i] <= 1'b1;
            end else if (exu_ioq_bcast.valid && exu_ioq_bcast.prd == uoq_pr2[i]) begin
              uoq_pv2[i]       <= exu_ioq_bcast.result;
              uoq_pv2_valid[i] <= 1'b1;
            end
          end
        end
      end
    end
  end

  // ================================================================
  // 2. Operand Bypass & Dispatch
  // ================================================================
  // PRF pre-read: drive read ports from enqueue-side rename results
  assign exu_prf.pr1_a = rnu_rou.pr1_a;
  assign exu_prf.pr2_a = rnu_rou.pr2_a;
`ifdef RAPT_DUAL_ISSUE
  assign exu_prf.pr1_b = rnu_rou.pr1_b;
  assign exu_prf.pr2_b = rnu_rou.pr2_b;
`endif

  // Bypass: use UOQ pre-read values + same-cycle broadcast forwarding
  logic pr1_a_from_uoq, pr1_a_from_ioq, pr1_a_from_exu, pr1_a_from_exu_b;
  logic pr2_a_from_uoq, pr2_a_from_ioq, pr2_a_from_exu, pr2_a_from_exu_b;

  assign pr1_a_from_uoq   = uoq_pv1_valid[uoq_tail_a];
  assign pr1_a_from_ioq   = exu_ioq_bcast.valid && (exu_ioq_bcast.prd == uoq_pr1[uoq_tail_a]);
  assign pr1_a_from_exu   = exu_rou.valid && (exu_rou.prd == uoq_pr1[uoq_tail_a]);
  assign pr1_a_from_exu_b = exu_rou_b.valid && (exu_rou_b.prd == uoq_pr1[uoq_tail_a]);

  assign pr2_a_from_uoq   = uoq_pv2_valid[uoq_tail_a];
  assign pr2_a_from_ioq   = exu_ioq_bcast.valid && (exu_ioq_bcast.prd == uoq_pr2[uoq_tail_a]);
  assign pr2_a_from_exu   = exu_rou.valid && (exu_rou.prd == uoq_pr2[uoq_tail_a]);
  assign pr2_a_from_exu_b = exu_rou_b.valid && (exu_rou_b.prd == uoq_pr2[uoq_tail_a]);

  logic pr1_a_ready, pr2_a_ready;
  assign pr1_a_ready = pr1_a_from_uoq || pr1_a_from_ioq || pr1_a_from_exu || pr1_a_from_exu_b;
  assign pr2_a_ready = pr2_a_from_uoq || pr2_a_from_ioq || pr2_a_from_exu || pr2_a_from_exu_b;

  always_comb begin
    rou_exu.uop = uoq_uops[uoq_tail_a];

    // Operand 1 selection (priority: UOQ pre-read > IOQ > EXU-A > EXU-B > immediate)
    rou_exu.op1 = (uoq_pr1[uoq_tail_a] != 0)
        ? (pr1_a_from_uoq ? uoq_pv1[uoq_tail_a]
         : pr1_a_from_ioq ? exu_ioq_bcast.result
         : pr1_a_from_exu ? exu_rou.result
         :                exu_rou_b.result)
        : uoq_op1[uoq_tail_a];

    // Operand 2 selection
    rou_exu.op2 = (uoq_pr2[uoq_tail_a] != 0)
        ? (pr2_a_from_uoq ? uoq_pv2[uoq_tail_a]
         : pr2_a_from_ioq ? exu_ioq_bcast.result
         : pr2_a_from_exu ? exu_rou.result
         :                exu_rou_b.result)
        : uoq_op2[uoq_tail_a];

    // Physical register IDs (zero if operand is ready = no scoreboard stall)
    rou_exu.pr1 = pr1_a_ready ? '0 : uoq_pr1[uoq_tail_a];
    rou_exu.pr2 = pr2_a_ready ? '0 : uoq_pr2[uoq_tail_a];
    rou_exu.prd = uoq_prd[uoq_tail_a];
    rou_exu.prs = uoq_prs[uoq_tail_a];

    // ROB destination tag: directly the slot this uop will occupy.
    rou_exu.dest = rob_tail_a;
  end

`ifdef RAPT_DUAL_ISSUE
  // ---- Slot B dispatch bypass & operand mux ----
  logic pr1_b_from_uoq, pr1_b_from_ioq, pr1_b_from_exu, pr1_b_from_exu_b;
  logic pr2_b_from_uoq, pr2_b_from_ioq, pr2_b_from_exu, pr2_b_from_exu_b;

  assign pr1_b_from_uoq   = uoq_pv1_valid[uoq_tail_b];
  assign pr1_b_from_ioq   = exu_ioq_bcast.valid && (exu_ioq_bcast.prd == uoq_pr1[uoq_tail_b]);
  assign pr1_b_from_exu   = exu_rou.valid && (exu_rou.prd == uoq_pr1[uoq_tail_b]);
  assign pr1_b_from_exu_b = exu_rou_b.valid && (exu_rou_b.prd == uoq_pr1[uoq_tail_b]);

  assign pr2_b_from_uoq   = uoq_pv2_valid[uoq_tail_b];
  assign pr2_b_from_ioq   = exu_ioq_bcast.valid && (exu_ioq_bcast.prd == uoq_pr2[uoq_tail_b]);
  assign pr2_b_from_exu   = exu_rou.valid && (exu_rou.prd == uoq_pr2[uoq_tail_b]);
  assign pr2_b_from_exu_b = exu_rou_b.valid && (exu_rou_b.prd == uoq_pr2[uoq_tail_b]);

  logic pr1_b_ready, pr2_b_ready;
  assign pr1_b_ready = pr1_b_from_uoq || pr1_b_from_ioq || pr1_b_from_exu || pr1_b_from_exu_b;
  assign pr2_b_ready = pr2_b_from_uoq || pr2_b_from_ioq || pr2_b_from_exu || pr2_b_from_exu_b;

  always_comb begin
    rou_exu.uop_b = uoq_uops[uoq_tail_b];

    rou_exu.op1_b = (uoq_pr1[uoq_tail_b] != 0)
        ? (pr1_b_from_uoq ? uoq_pv1[uoq_tail_b]
         : pr1_b_from_ioq ? exu_ioq_bcast.result
         : pr1_b_from_exu ? exu_rou.result
         :                  exu_rou_b.result)
        : uoq_op1[uoq_tail_b];

    rou_exu.op2_b = (uoq_pr2[uoq_tail_b] != 0)
        ? (pr2_b_from_uoq ? uoq_pv2[uoq_tail_b]
         : pr2_b_from_ioq ? exu_ioq_bcast.result
         : pr2_b_from_exu ? exu_rou.result
         :                  exu_rou_b.result)
        : uoq_op2[uoq_tail_b];

    rou_exu.pr1_b = pr1_b_ready ? '0 : uoq_pr1[uoq_tail_b];
    rou_exu.pr2_b = pr2_b_ready ? '0 : uoq_pr2[uoq_tail_b];
    rou_exu.prd_b = uoq_prd[uoq_tail_b];
    rou_exu.prs_b = uoq_prs[uoq_tail_b];

    rou_exu.dest_b = rob_tail_b;
  end
`endif

  // ================================================================
  // 3. Reorder Buffer (ROB) - uses rob_entry_t struct array
  // ================================================================

  // Write-back destination index decoding (dest is already 0-indexed ROB slot)
  logic [$clog2(ROB_SIZE)-1:0] wb_dest_exu, wb_dest_exu_b, wb_dest_ioq;
  assign wb_dest_exu   = exu_rou.dest;
  assign wb_dest_exu_b = exu_rou_b.dest;
  assign wb_dest_ioq   = exu_ioq_bcast.dest;

  always_ff @(posedge clock) begin
    if (reset || flush_pipe) begin
      rob_head         <= '0;
      rob_tail_a       <= '0;
      recieved_trap    <= 1'b0;
      recieved_sw_trap <= 1'b0;
      trap_cause       <= '0;
      for (int i = 0; i < ROB_SIZE; i++) begin
        rob_entry[i].busy  <= 1'b0;
        rob_entry[i].state <= rapt_pkg::ROB_CM;
      end
    end else begin
      // ---- Dispatch: insert into ROB tail ----
      if (uoq_deq_fire_a) begin
`ifdef RAPT_DUAL_ISSUE
        rob_tail_a <= uoq_deq_fire_b ? rob_tail_a + 2 : rob_tail_a + 1;
`else
        rob_tail_a <= rob_tail_a + 1;
`endif

        rob_entry[rob_tail_a].prd <= uoq_prd[uoq_tail_a];
        rob_entry[rob_tail_a].prs <= uoq_prs[uoq_tail_a];
        rob_entry[rob_tail_a].busy <= 1'b1;
        rob_entry[rob_tail_a].state <= rapt_pkg::ROB_EX;
        rob_entry[rob_tail_a].rd <= uoq_uops[uoq_tail_a].rd;

        rob_entry[rob_tail_a].ben <= uoq_uops[uoq_tail_a].ben;
        rob_entry[rob_tail_a].jen <= uoq_uops[uoq_tail_a].jen;
        rob_entry[rob_tail_a].jren <= uoq_uops[uoq_tail_a].jren;
        rob_entry[rob_tail_a].pnpc <= uoq_uops[uoq_tail_a].pnpc;

        rob_entry[rob_tail_a].wen <= uoq_uops[uoq_tail_a].wen;
        rob_entry[rob_tail_a].word <= uoq_uops[uoq_tail_a].word;
        rob_entry[rob_tail_a].alu <= uoq_uops[uoq_tail_a].atom ?
        `RAPT_WSTRB_SW
        : uoq_uops[uoq_tail_a].alu;

        rob_entry[rob_tail_a].atom <= uoq_uops[uoq_tail_a].atom;
        rob_entry[rob_tail_a].atom_sc <= uoq_uops[uoq_tail_a].atom
                                    && (uoq_uops[uoq_tail_a].alu == `RAPT_ATO_SC__);

        rob_entry[rob_tail_a].trap <= uoq_uops[uoq_tail_a].trap;
        rob_entry[rob_tail_a].tval <= uoq_uops[uoq_tail_a].tval;
        rob_entry[rob_tail_a].cause <= uoq_uops[uoq_tail_a].cause;

        rob_entry[rob_tail_a].pc <= uoq_uops[uoq_tail_a].pc;

        // Cold dispatch-only payload (RS issue + commit display)
        uop_pl[rob_tail_a].sys <= uoq_uops[uoq_tail_a].system;
        uop_pl[rob_tail_a].ecall <= uoq_uops[uoq_tail_a].ecall;
        uop_pl[rob_tail_a].ebreak <= uoq_uops[uoq_tail_a].ebreak;
        uop_pl[rob_tail_a].mret <= uoq_uops[uoq_tail_a].mret;
        uop_pl[rob_tail_a].sret <= uoq_uops[uoq_tail_a].sret;
        uop_pl[rob_tail_a].f_i <= uoq_uops[uoq_tail_a].f_i;
        uop_pl[rob_tail_a].f_time <= uoq_uops[uoq_tail_a].f_time;
        uop_pl[rob_tail_a].csr_addr <= uoq_uops[uoq_tail_a].imm[11:0];
        uop_pl[rob_tail_a].csr_csw <= uoq_uops[uoq_tail_a].csr_csw;
        uop_pl[rob_tail_a].inst <= uoq_uops[uoq_tail_a].inst;

`ifdef RAPT_DUAL_ISSUE
        // ---- Dispatch slot B: insert into ROB tail+1 ----
        if (uoq_deq_fire_b) begin
          rob_entry[rob_tail_b].prd <= uoq_prd[uoq_tail_b];
          rob_entry[rob_tail_b].prs <= uoq_prs[uoq_tail_b];
          rob_entry[rob_tail_b].busy <= 1'b1;
          rob_entry[rob_tail_b].state <= rapt_pkg::ROB_EX;
          rob_entry[rob_tail_b].rd <= uoq_uops[uoq_tail_b].rd;

          rob_entry[rob_tail_b].ben <= uoq_uops[uoq_tail_b].ben;
          rob_entry[rob_tail_b].jen <= uoq_uops[uoq_tail_b].jen;
          rob_entry[rob_tail_b].jren <= uoq_uops[uoq_tail_b].jren;
          rob_entry[rob_tail_b].pnpc <= uoq_uops[uoq_tail_b].pnpc;

          rob_entry[rob_tail_b].wen <= uoq_uops[uoq_tail_b].wen;
          rob_entry[rob_tail_b].word <= uoq_uops[uoq_tail_b].word;
          rob_entry[rob_tail_b].alu <= uoq_uops[uoq_tail_b].atom ?
          `RAPT_WSTRB_SW
          : uoq_uops[uoq_tail_b].alu;

          rob_entry[rob_tail_b].atom <= uoq_uops[uoq_tail_b].atom;
          rob_entry[rob_tail_b].atom_sc <= uoq_uops[uoq_tail_b].atom
                                        && (uoq_uops[uoq_tail_b].alu == `RAPT_ATO_SC__);

          rob_entry[rob_tail_b].trap <= uoq_uops[uoq_tail_b].trap;
          rob_entry[rob_tail_b].tval <= uoq_uops[uoq_tail_b].tval;
          rob_entry[rob_tail_b].cause <= uoq_uops[uoq_tail_b].cause;

          rob_entry[rob_tail_b].pc <= uoq_uops[uoq_tail_b].pc;

          // Cold dispatch-only payload (RS issue + commit display)
          uop_pl[rob_tail_b].sys <= uoq_uops[uoq_tail_b].system;
          uop_pl[rob_tail_b].ecall <= uoq_uops[uoq_tail_b].ecall;
          uop_pl[rob_tail_b].ebreak <= uoq_uops[uoq_tail_b].ebreak;
          uop_pl[rob_tail_b].mret <= uoq_uops[uoq_tail_b].mret;
          uop_pl[rob_tail_b].sret <= uoq_uops[uoq_tail_b].sret;
          uop_pl[rob_tail_b].f_i <= uoq_uops[uoq_tail_b].f_i;
          uop_pl[rob_tail_b].f_time <= uoq_uops[uoq_tail_b].f_time;
          uop_pl[rob_tail_b].csr_addr <= uoq_uops[uoq_tail_b].imm[11:0];
          uop_pl[rob_tail_b].csr_csw <= uoq_uops[uoq_tail_b].csr_csw;
          uop_pl[rob_tail_b].inst <= uoq_uops[uoq_tail_b].inst;
        end
`endif
      end

      // ---- Write-back from IOQ (load/store completion) ----
      if (exu_ioq_bcast.valid) begin
        rob_entry[wb_dest_ioq].state    <= rapt_pkg::ROB_WB;
        rob_entry[wb_dest_ioq].npc      <= exu_ioq_bcast.npc;
        rob_entry[wb_dest_ioq].wen      <= exu_ioq_bcast.wen;
        rob_entry[wb_dest_ioq].sq_waddr <= exu_ioq_bcast.sq_waddr;
        rob_entry[wb_dest_ioq].sq_wdata <= exu_ioq_bcast.sq_wdata;

        if (exu_ioq_bcast.trap) begin
          rob_entry[wb_dest_ioq].rd  <= '0;
          rob_entry[wb_dest_ioq].wen <= 1'b0;
        end

        rob_entry[wb_dest_ioq].trap <= exu_ioq_bcast.trap;
        rob_entry[wb_dest_ioq].tval <= exu_ioq_bcast.tval;
        rob_entry[wb_dest_ioq].cause <= exu_ioq_bcast.cause;
        rob_entry[wb_dest_ioq].difftest_skip <= exu_ioq_bcast.difftest_skip;
      end

      // ---- Write-back from EXU (ALU/branch completion) ----
      if (exu_rou.valid) begin
        rob_entry[wb_dest_exu].state         <= rapt_pkg::ROB_WB;
        rob_entry[wb_dest_exu].btaken        <= exu_rou.btaken;
        rob_entry[wb_dest_exu].npc           <= exu_rou.npc;

        rob_entry[wb_dest_exu].csr_wen       <= exu_rou.csr_wen;
        rob_entry[wb_dest_exu].csr_wdata     <= exu_rou.csr_wdata;

        rob_entry[wb_dest_exu].trap          <= exu_rou.trap;
        rob_entry[wb_dest_exu].tval          <= exu_rou.tval;
        rob_entry[wb_dest_exu].cause         <= exu_rou.cause;
        rob_entry[wb_dest_exu].difftest_skip <= exu_rou.difftest_skip;
      end

      // ---- Write-back from EXU slot B (pure ALU + BRU completion) ----
      // Slot B handles arithmetic and branches (jen / ben). It never carries
      // CSR/trap/system/mul, so dispatch-time fields (csr_wen, ecall, mret,
      // trap, ...) stay at their defaults (0). We update state/npc/btaken/
      // inst/difftest_skip; btaken is required for BPU updates on commit.
      if (exu_rou_b.valid) begin
        rob_entry[wb_dest_exu_b].state         <= rapt_pkg::ROB_WB;
        rob_entry[wb_dest_exu_b].npc           <= exu_rou_b.npc;
        rob_entry[wb_dest_exu_b].btaken        <= exu_rou_b.btaken;
        rob_entry[wb_dest_exu_b].difftest_skip <= exu_rou_b.difftest_skip;
      end

      // ---- Write-back from EXU port C (dedicated BRU, ben only) ----
      // Conditional branches don't write rd, so no result/prd update is
      // needed; only state + npc + btaken + difftest_skip are written so
      // commit/BPU can resolve the branch.
      if (exu_rou_c.valid) begin
        rob_entry[exu_rou_c.dest].state         <= rapt_pkg::ROB_WB;
        rob_entry[exu_rou_c.dest].npc           <= exu_rou_c.npc;
        rob_entry[exu_rou_c.dest].btaken        <= exu_rou_c.btaken;
        rob_entry[exu_rou_c.dest].difftest_skip <= exu_rou_c.difftest_skip;
      end

      // ---- Commit: retire ROB entries (up to 2 per cycle) ----
      // Note: data fields (sq_waddr/sq_wdata/csr_wdata/cause/...) are
      // intentionally NOT cleared here. Reads are all gated by `busy` /
      // `wen` / `trap` / `csr_wen`, so leaving stale data in place is safe
      // and removes head0_valid from the ROB-wide data-flop D-mux fanin
      // (significant for STA: head0_valid drives ~ROB_SIZE * (sq_waddr +
      // sq_wdata + csr_wdata + ...) wide D ports otherwise).
      if (head0_valid) begin
        rob_head                     <= dual_commit ? rob_head + 2 : rob_head + 1;

        rob_entry[rob_head].busy     <= 1'b0;
        rob_entry[rob_head].state    <= rapt_pkg::ROB_CM;
        rob_entry[rob_head].csr_wen  <= 1'b0;
        rob_entry[rob_head].trap     <= 1'b0;
        rob_entry[rob_head].wen      <= 1'b0;

        if (dual_commit) begin
          rob_entry[h1].busy     <= 1'b0;
          rob_entry[h1].state    <= rapt_pkg::ROB_CM;
          rob_entry[h1].csr_wen  <= 1'b0;
          rob_entry[h1].trap     <= 1'b0;
          rob_entry[h1].wen      <= 1'b0;
        end

        recieved_trap    <= clint_sw_trap || clint_timer_trap || clint_ext_trap || s_int_pending;
        recieved_sw_trap <= clint_sw_trap;
        // Cause priority: MEI > MSI > MTI > S-mode delegated
        // (RISC-V Priv §3.1.9 ordering for M-mode sources, then S-level).
        if (clint_ext_trap) trap_cause <= XLEN'(`RAPT_CAUSE_MEI) | (XLEN'(1) << (XLEN - 1));
        else if (clint_sw_trap) trap_cause <= XLEN'(`RAPT_CAUSE_MSI) | (XLEN'(1) << (XLEN - 1));
        else if (clint_timer_trap) trap_cause <= XLEN'(`RAPT_CAUSE_MTI) | (XLEN'(1) << (XLEN - 1));
        else if (s_int_pending) trap_cause <= s_int_cause;
        trap_pc <= dual_commit ? rob_entry[h1].npc : rob_entry[rob_head].npc;
      end
    end
  end

  // ---- Slot 0 (head) ----
  assign head0_br_p_fail = rob_entry[h0].npc != rob_entry[h0].pnpc;
  assign head0_valid     = recieved_trap || (
      rob_entry[h0].busy
      && rob_entry[h0].state == rapt_pkg::ROB_WB
      && (rou_lsu.sq_ready || !rob_entry[h0].wen));

  // Pure CSR: sys instruction without ecall/ebreak/mret/sret (no redirect needed)
  logic head0_sys_pure;
  assign head0_sys_pure = uop_pl[h0].sys
      && !uop_pl[h0].ecall && !uop_pl[h0].ebreak
      && !uop_pl[h0].mret  && !uop_pl[h0].sret;

  logic head0_flush;
  assign head0_flush = recieved_trap || (head0_valid && (
      uop_pl[h0].f_i
      || head0_br_p_fail
      || rob_entry[h0].trap
      || uop_pl[h0].sys
      || uop_pl[h0].f_time
      || rob_entry[h0].atom
  ));

  // Kept as a distinct broadcast path for interface compatibility. Pure
  // CSR/f_time currently take the full flush path above so any younger
  // speculative uops are discarded before dispatch resumes.
  assign sys_resume = head0_valid && (head0_sys_pure || uop_pl[h0].f_time) && !head0_flush;

  // ---- Slot 1 (head+1): only considered when slot 0 doesn't flush ----
  logic head1_br_p_fail;
  logic head1_valid;
  assign head1_br_p_fail = rob_entry[h1].npc != rob_entry[h1].pnpc;
  assign head1_valid     = rob_entry[h1].busy
      && rob_entry[h1].state == rapt_pkg::ROB_WB
      && (rou_lsu.sq_ready || !rob_entry[h1].wen);

  // Dual commit: slot 0 doesn't flush, isn't a store, and slot 1 ready.
  // Also guard against difftest_skip to simplify simulation infrastructure.
`ifdef RAPT_DUAL_COMMIT
  assign dual_commit = head0_valid && !head0_flush
      && !rob_entry[h0].wen && head1_valid
      && !rob_entry[h0].difftest_skip && !rob_entry[h1].difftest_skip;
`else
  assign dual_commit = 1'b0;
`endif

  // Slot 1 flush
  logic head1_flush;
  assign head1_flush = dual_commit && (
      uop_pl[h1].f_i
      || head1_br_p_fail
      || rob_entry[h1].trap
      || uop_pl[h1].sys
      || uop_pl[h1].f_time
      || rob_entry[h1].atom
  );

  // ---- Global flush / fence ----
  assign fence_time = (head0_valid && uop_pl[h0].f_time) || (dual_commit && uop_pl[h1].f_time);
  assign flush_pipe = head0_flush || head1_flush;

  // PMU: SQ-specific commit stall (ROB head is a ready store blocked by full SQ)
  /* verilator lint_off UNUSEDSIGNAL */
  logic pmu_sq_stall;
  assign pmu_sq_stall = !recieved_trap
      && rob_entry[h0].busy && rob_entry[h0].state == rapt_pkg::ROB_WB
      && rob_entry[h0].wen  && !rou_lsu.sq_ready;
  /* verilator lint_on UNUSEDSIGNAL */

  // ---- CMU interface (slot A) ----
  assign rou_cmu.rd_a = recieved_trap ? '0 : rob_entry[h0].rd;
  // Surface the real fetched instruction, even on traps (for difftest/RVFI).
  // The architectural state (mcause/mepc/mtval) reflects the trap; downstream
  // consumers use `inst` only for trace/diff reporting.
  assign rou_cmu.inst_a = uop_pl[h0].inst;
  assign rou_cmu.pc_a = recieved_trap ? trap_pc : rob_entry[h0].pc;
  assign rou_cmu.prd_a = rob_entry[h0].prd;
  assign rou_cmu.prs_a = rob_entry[h0].prs;
  // Branch signals: when dual committing, use slot 1 (BPU trains on rpc which is slot 1's PC)
  assign rou_cmu.btaken = dual_commit ? rob_entry[h1].btaken : rob_entry[h0].btaken;
  assign rou_cmu.npc_a       = dual_commit
      ? ((rob_entry[h1].trap || uop_pl[h1].ecall || uop_pl[h1].ebreak)
          ? csr_bcast.tvec : rob_entry[h1].npc)
      : (recieved_trap || rob_entry[h0].trap
          || uop_pl[h0].ecall || uop_pl[h0].ebreak)
          ? csr_bcast.tvec
      : rob_entry[h0].npc;
  assign rou_cmu.ben = dual_commit ? rob_entry[h1].ben : rob_entry[h0].ben;
  assign rou_cmu.jen = dual_commit ? rob_entry[h1].jen : rob_entry[h0].jen;
  assign rou_cmu.jren = dual_commit ? rob_entry[h1].jren : rob_entry[h0].jren;
  assign rou_cmu.atomic_sc = dual_commit ? rob_entry[h1].atom_sc : rob_entry[h0].atom_sc;
  assign rou_cmu.ebreak_a = head0_valid && uop_pl[h0].ebreak;
  assign rou_cmu.fence_time = fence_time;
  assign rou_cmu.fence_i = (head0_valid && uop_pl[h0].f_i) || (dual_commit && uop_pl[h1].f_i);
  assign rou_cmu.flush_pipe = flush_pipe;
  assign rou_cmu.sys_resume = sys_resume;
  assign rou_cmu.time_trap = recieved_trap;
  assign rou_cmu.rob_head = rob_head;
  // Per-cycle ROB head advance: matches the rob_head update logic at L611
  // (dual_commit ? +2 : +1 when head0_valid commits this cycle, else 0).
  assign rou_cmu.difftest_skip_a = !recieved_trap && rob_entry[h0].difftest_skip;
  assign rou_cmu.valid_a = recieved_trap ? 1'b0 : head0_valid;

  // ---- CMU interface (slot B: dual commit) ----
  assign rou_cmu.rd_b = rob_entry[h1].rd;
  // Surface the real fetched instruction, even on traps (for difftest/RVFI).
  assign rou_cmu.inst_b = uop_pl[h1].inst;
  assign rou_cmu.pc_b = rob_entry[h1].pc;
  assign rou_cmu.prd_b = rob_entry[h1].prd;
  assign rou_cmu.prs_b = rob_entry[h1].prs;
  assign rou_cmu.npc_b = (rob_entry[h1].trap || uop_pl[h1].ecall || uop_pl[h1].ebreak)
      ? csr_bcast.tvec : rob_entry[h1].npc;
  assign rou_cmu.ebreak_b = dual_commit && uop_pl[h1].ebreak;
  assign rou_cmu.difftest_skip_b = rob_entry[h1].difftest_skip;
  assign rou_cmu.valid_b = dual_commit;

`ifdef RAPT_RVFI
  // ---- RVFI per-slot data ----
  assign rou_cmu.rvfi_trap_a = !recieved_trap && rob_entry[h0].trap;
  assign rou_cmu.rvfi_trap_b = rob_entry[h1].trap;
  assign rou_cmu.rvfi_npc_a  = (rob_entry[h0].trap || uop_pl[h0].ecall || uop_pl[h0].ebreak)
      ? csr_bcast.tvec : rob_entry[h0].npc;
  assign rou_cmu.rvfi_sq_waddr_a = rob_entry[h0].sq_waddr;
  assign rou_cmu.rvfi_sq_waddr_b = rob_entry[h1].sq_waddr;
  assign rou_cmu.rvfi_sq_wdata_a = rob_entry[h0].sq_wdata;
  assign rou_cmu.rvfi_sq_wdata_b = rob_entry[h1].sq_wdata;
`endif

  // ---- CSR interface (MUX slot 0 / slot 1) ----
  // Slot 0 never has sys/trap during dual commit (they cause flush).
  // When dual committing, route slot 1's CSR/sys info if present.
  logic csr_from_h1;
  assign csr_from_h1 = dual_commit && (uop_pl[h1].sys || rob_entry[h1].trap);

  // An illegal-inst or IFU page-fault may set trap=1 on a uop that still
  // carries decoded sret/mret/ecall/ebreak/csr_wen bits. Gate these so the
  // trap handler (rou_csr.trap path) is the sole side effect.
  logic commit_trap;
  assign commit_trap = csr_from_h1 ? rob_entry[h1].trap : rob_entry[h0].trap;

  assign rou_csr.pc = recieved_trap ? trap_pc : csr_from_h1 ? rob_entry[h1].pc : rob_entry[h0].pc;
  assign rou_csr.csr_wen   = (recieved_trap || commit_trap) ? 1'b0
                           : csr_from_h1   ? rob_entry[h1].csr_wen
                           :                 rob_entry[h0].csr_wen;
  assign rou_csr.csr_wdata = csr_from_h1 ? rob_entry[h1].csr_wdata : rob_entry[h0].csr_wdata;
  assign rou_csr.csr_addr = csr_from_h1 ? uop_pl[h1].csr_addr : uop_pl[h0].csr_addr;
  assign rou_csr.ecall     = (recieved_trap || commit_trap) ? 1'b0
                           : csr_from_h1 ? uop_pl[h1].ecall : uop_pl[h0].ecall;
  assign rou_csr.ebreak    = (recieved_trap || commit_trap) ? 1'b0
                           : csr_from_h1   ? uop_pl[h1].ebreak
                           :                 uop_pl[h0].ebreak;
  assign rou_csr.mret      = (recieved_trap || commit_trap) ? 1'b0
                           : csr_from_h1 ? uop_pl[h1].mret : uop_pl[h0].mret;
  assign rou_csr.sret      = (recieved_trap || commit_trap) ? 1'b0
                           : csr_from_h1 ? uop_pl[h1].sret : uop_pl[h0].sret;
  assign rou_csr.trap = recieved_trap || commit_trap;
  assign rou_csr.tval = recieved_trap ? '0 : csr_from_h1 ? rob_entry[h1].tval : rob_entry[h0].tval;
  assign rou_csr.cause     = recieved_trap
      ? trap_cause
      : csr_from_h1 ? rob_entry[h1].cause
      :               rob_entry[h0].cause;
  assign rou_csr.valid     = recieved_trap
      || (head0_valid && (uop_pl[h0].sys || rob_entry[h0].trap))
      || csr_from_h1;

  // ---- LSU interface (store commit: MUX slot 0 / slot 1) ----
  // During dual commit, slot 0 is guaranteed non-store; route slot 1.
  assign rou_lsu.store = recieved_trap ? 1'b0 : dual_commit ? rob_entry[h1].wen : rob_entry[h0].wen;
  assign rou_lsu.alu = dual_commit ? rob_entry[h1].alu : rob_entry[h0].alu;
  assign rou_lsu.sq_waddr = dual_commit ? rob_entry[h1].sq_waddr : rob_entry[h0].sq_waddr;
  assign rou_lsu.sq_vaddr = dual_commit ? rob_entry[h1].tval : rob_entry[h0].tval;
  assign rou_lsu.sq_wdata = dual_commit ? rob_entry[h1].sq_wdata : rob_entry[h0].sq_wdata;
  assign rou_lsu.pc = dual_commit ? rob_entry[h1].pc : rob_entry[h0].pc;
  assign rou_lsu.valid = head0_valid;

  // ---- Retire count for instret CSR ----
  assign rou_csr.retire_a = head0_valid;
  assign rou_csr.retire_b = dual_commit;

  // ==========================================================================
  //  Assertions (enable with +define+RAPT_ASSERT_EN)
  // ==========================================================================

  // COMMIT_DURABLE: when committing a store, the ROB entry at the commit slot
  // must have non-X vaddr/waddr (writeback already captured them).
  `RAPT_SVA_IMPLY(clock, reset, ROB_STORE_HAS_ADDR, (rou_lsu.valid && rou_lsu.store), (!$isunknown
                  (rou_lsu.sq_vaddr) && !$isunknown(rou_lsu.sq_waddr)))

  // DUAL_COMMIT_SEMANTICS: slot 0 cannot be a store when dual-committing
  // (hard microarchitectural invariant; slot 1 carries the store).
  `RAPT_SVA_IMPLY(clock, reset, ROB_DUAL_COMMIT_SLOT0_NO_STORE, (dual_commit), (!rob_entry[h0].wen))

  // COMMIT_DURABLE: a valid commit requires the ROB head entry to be busy
  // (holding a uop) — prevents retiring an empty slot.
  `RAPT_SVA_IMPLY(clock, reset, ROB_COMMIT_NEEDS_BUSY, (head0_valid && !recieved_trap),
                  (rob_entry[h0].busy))

  `RAPT_SVA_IMPLY(clock, reset, ROB_SYS_SERIALIZING_FLUSH,
                  (head0_valid && (uop_pl[h0].sys || uop_pl[h0].f_time)), flush_pipe)

  `RAPT_SVA_IMPLY(clock, reset, ROB_DUAL_SERIALIZING_FLUSH,
                  (dual_commit && (uop_pl[h1].sys || uop_pl[h1].f_time)), flush_pipe)

  // Coverage: flush events happen (sanity that the DUT actually exercises
  // flush paths during tests — guards against accidentally disabling flush).
  `RAPT_COVER(clock, reset, ROB_FLUSH_EVENT, cmu_bcast.flush_pipe)

endmodule

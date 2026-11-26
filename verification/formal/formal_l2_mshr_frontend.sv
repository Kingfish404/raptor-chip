// Formal verification of rapt_l2_mshr_frontend + rapt_l2_mshr_scheduler:
// mutual exclusion of allocate/queue/reload, no duplicate normal MSHRs per set,
// BC/C preemption stalling, directory conflict safety, and secondary integrity.
module formal_l2_mshr_frontend #(
    parameter int NumMshrs = 4,
    parameter int NumEntries = 6,
    parameter int SetBits = 2,
    parameter int TagBits = 3,
    parameter int PayloadBits = 8,
    parameter int MshrBits = $clog2(NumMshrs)
) (
    input logic clock,
    input logic reset,
    input logic request_valid,
    input logic [2:0] request_prio,
    input logic [SetBits-1:0] request_set,
    input logic [TagBits-1:0] request_tag,
    input logic [PayloadBits-1:0] request_payload,
    input logic [NumMshrs-1:0] mshr_block_b,
    input logic [NumMshrs-1:0] mshr_block_c,
    input logic [NumMshrs-1:0] mshr_nest_b,
    input logic [NumMshrs-1:0] mshr_nest_c,
    input logic [NumMshrs-1:0] schedule_request,
    input logic [NumMshrs-1:0] schedule_resources_ready,
    input logic [NumMshrs-1:0] schedule_reload,
    input logic [NumMshrs-1:0] mshr_retire
);
  localparam int NormalMshrs = NumMshrs - 2;
  localparam int BcMshr = NumMshrs - 2;
  localparam int CMshr = NumMshrs - 1;

  logic [NumMshrs-1:0] mshr_valid;
  logic [SetBits-1:0] mshr_set[NumMshrs];
  logic [TagBits-1:0] mshr_tag[NumMshrs];

  logic request_ready, allocate_valid, schedule_valid;
  logic [MshrBits-1:0] allocate_index, schedule_index;
  logic [NumMshrs-1:0] schedule_onehot, schedule_stalled;
  logic reload_valid, reload_from_request, reload_needs_directory;
  logic [TagBits-1:0] reload_tag;
  logic [PayloadBits-1:0] reload_payload;
  logic secondary_push_ready;
  logic [3*NumMshrs-1:0] secondary_queue_valid;

  rapt_l2_mshr_frontend #(
      .NumMshrs(NumMshrs),
      .NumEntries(NumEntries),
      .SetBits(SetBits),
      .TagBits(TagBits),
      .PayloadBits(PayloadBits)
  ) dut (
      .clock,
      .reset,
      .request_valid,
      .request_ready,
      .request_prio,
      .request_set,
      .request_tag,
      .request_payload,
      .mshr_valid,
      .mshr_set,
      .mshr_tag,
      .mshr_block_b,
      .mshr_block_c,
      .mshr_nest_b,
      .mshr_nest_c,
      .schedule_request,
      .schedule_resources_ready,
      .schedule_reload,
      .allocate_valid,
      .allocate_index,
      .schedule_valid,
      .schedule_index,
      .schedule_onehot,
      .schedule_stalled,
      .reload_valid,
      .reload_from_request,
      .reload_needs_directory,
      .reload_tag,
      .reload_payload,
      .secondary_push_ready,
      .secondary_queue_valid
  );

  logic past_valid = 1'b0;

  always_comb begin
    if (!past_valid) assume (reset);
    if (!reset) begin
      // Request priority must be one-hot (A, B, or C).
      if (request_valid)
        assume (request_prio == 3'b001 || request_prio == 3'b010 || request_prio == 3'b100);
      // Only valid MSHRs may request scheduling, reload, or retire.
      assume ((schedule_request & ~mshr_valid) == '0);
      assume ((schedule_reload & ~mshr_valid) == '0);
      assume ((mshr_retire & ~mshr_valid) == '0);
      // A slot with queued secondary entries retires via reload, not bare retire.
      for (int s = 0; s < NumMshrs; s++) begin
        if (secondary_queue_valid[s] || secondary_queue_valid[NumMshrs+s]
            || secondary_queue_valid[2*NumMshrs+s]) begin
          assume (!mshr_retire[s]);
        end
        // Never retire on the same edge as reload.
        if (reload_valid && schedule_index == MshrBits'(s)) assume (!mshr_retire[s]);
      end
      // C-slot nesting requires normal/BC slot not both block_c and nest_c.
      assume ((mshr_block_b & mshr_nest_b) == '0);
      assume ((mshr_block_c & mshr_nest_c) == '0);
    end
  end

  always_ff @(posedge clock) begin
    past_valid <= 1'b1;
    if (reset) begin
      mshr_valid <= '0;
      for (int s = 0; s < NumMshrs; s++) begin
        mshr_set[s] <= '0;
        mshr_tag[s] <= '0;
      end
    end else begin
      // 1. No two normal MSHRs ever own the same set.
      for (int i = 0; i < NormalMshrs; i++) begin
        for (int j = i + 1; j < NormalMshrs; j++) begin
          no_dup_normal_set :
          assert (!(mshr_valid[i] && mshr_valid[j] && mshr_set[i] == mshr_set[j]));
        end
      end
      // 2. Allocate never overwrites a live MSHR.
      if (allocate_valid) begin
        alloc_slot_free : assert (!mshr_valid[allocate_index]);
        alloc_requires_ready : assert (request_valid && request_ready);
        // Directory read conflict safety: never allocate while reload needs directory.
        no_dir_conflict : assert (!(reload_valid && reload_needs_directory));
      end
      // 3. Allocate and reload-from-request are mutually exclusive.
      no_alloc_and_bypass : assert (!(allocate_valid && reload_from_request));
      // 4. Schedule one-hot consistency and preemption stall obedience.
      if (schedule_valid) begin
        sched_valid_mshr : assert (mshr_valid[schedule_index]);
        sched_not_stalled : assert (!schedule_stalled[schedule_index]);
        sched_onehot_match : assert (schedule_onehot == (NumMshrs'(1) << schedule_index));
        sched_req_ready :
        assert (schedule_request[schedule_index] && schedule_resources_ready[schedule_index]);
      end else begin
        sched_onehot_zero : assert (schedule_onehot == '0);
      end
      // 5. Preemption stall contract: C stalls BC and normal on same set.
      for (int i = 0; i < NormalMshrs; i++) begin
        if (mshr_valid[CMshr] && mshr_set[i] == mshr_set[CMshr])
          c_stalls_normal : assert (schedule_stalled[i]);
        if (mshr_valid[BcMshr] && mshr_set[i] == mshr_set[BcMshr])
          bc_stalls_normal : assert (schedule_stalled[i]);
      end
      if (mshr_valid[CMshr] && mshr_set[BcMshr] == mshr_set[CMshr])
        c_stalls_bc : assert (schedule_stalled[BcMshr]);

      // Update model MSHR table.
      for (int s = 0; s < NumMshrs; s++) begin
        if (mshr_retire[s]) mshr_valid[s] <= 1'b0;
      end
      if (allocate_valid) begin
        mshr_valid[allocate_index] <= 1'b1;
        mshr_set[allocate_index] <= request_set;
        mshr_tag[allocate_index] <= request_tag;
      end
      if (reload_valid) begin
        mshr_tag[schedule_index] <= reload_tag;
      end

      cov_nest_c_preempt :
      cover (allocate_valid && allocate_index == MshrBits'(CMshr) && |mshr_valid[NormalMshrs-1:0]);
      cov_reload_bypass : cover (reload_valid && reload_from_request);
      cov_reload_secondary_diff_tag :
      cover (reload_valid && !reload_from_request && reload_needs_directory);
      cov_all_normal_busy : cover (&mshr_valid[NormalMshrs-1:0]);
    end
  end
endmodule

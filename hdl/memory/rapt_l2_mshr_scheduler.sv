// BOOM inclusive-cache MSHR allocation and round-robin schedule selection.
// Five ordinary A slots and the dedicated BC/C slots share one set-conflict
// table. The secondary request payloads reside in rapt_l2_secondary_buffer.
module rapt_l2_mshr_scheduler #(
    parameter int NumMshrs = 7,
    parameter int SetBits = 10,
    parameter int TagBits = 18,
    parameter int NormalMshrs = NumMshrs - 2,
    parameter int MshrBits = (NumMshrs <= 1) ? 1 : $clog2(NumMshrs),
    parameter int QueueBits = $clog2(3 * NumMshrs)
) (
    input logic clock,
    input logic reset,
    input logic request_valid,
    output logic request_ready,
    input logic [2:0] request_prio,
    input logic [SetBits-1:0] request_set,
    input logic [TagBits-1:0] request_tag,
    input logic [NumMshrs-1:0] mshr_valid,
    input logic [SetBits-1:0] mshr_set[NumMshrs],
    input logic [TagBits-1:0] mshr_tag[NumMshrs],
    input logic [NumMshrs-1:0] mshr_block_b,
    input logic [NumMshrs-1:0] mshr_block_c,
    input logic [NumMshrs-1:0] mshr_nest_b,
    input logic [NumMshrs-1:0] mshr_nest_c,
    input logic secondary_push_ready,
    input logic [3*NumMshrs-1:0] secondary_queue_valid,
    input logic [TagBits-1:0] secondary_head_tag,
    output logic secondary_push_valid,
    output logic [QueueBits-1:0] secondary_push_index,
    output logic secondary_pop_valid,
    output logic [QueueBits-1:0] secondary_pop_index,
    output logic allocate_valid,
    output logic [MshrBits-1:0] allocate_index,
    input logic [NumMshrs-1:0] schedule_request,
    input logic [NumMshrs-1:0] schedule_resources_ready,
    input logic [NumMshrs-1:0] schedule_reload,
    output logic schedule_valid,
    output logic [MshrBits-1:0] schedule_index,
    output logic [NumMshrs-1:0] schedule_onehot,
    output logic [NumMshrs-1:0] schedule_stalled,
    output logic reload_valid,
    output logic reload_from_request,
    output logic reload_needs_directory
);
  if (NumMshrs < 3 || NormalMshrs != NumMshrs - 2 || SetBits < 1 || TagBits < 1)
    $error("invalid L2 MSHR geometry");

  localparam int BcMshr = NumMshrs - 2;
  localparam int CMshr  = NumMshrs - 1;
  logic [NumMshrs-1:0] set_matches, prio_filter, lower_matches;
  logic [NumMshrs-1:0] free_matches;
  logic block_b, block_c, nest_b, nest_c;
  logic alloc, queue, free_found, queue_target_found;
  logic secondary_a_valid, secondary_b_valid, secondary_c_valid;
  logic secondary_may_pop, bypass_matches, bypass, bypass_queue;
  logic reload_directory_conflict;
  logic [MshrBits-1:0] free_index, queue_target;
  logic [MshrBits-1:0] last_schedule;

  always_comb begin
    for (int slot = 0; slot < NumMshrs; slot++) begin
      set_matches[slot] = mshr_valid[slot] && mshr_set[slot] == request_set;
      prio_filter[slot] = slot < NormalMshrs || (slot == BcMshr && !request_prio[0])
                          || (slot == CMshr && request_prio[2]);
    end
  end
  assign lower_matches = set_matches & prio_filter;
  assign free_matches = ~mshr_valid & prio_filter;
  assign alloc = !(|set_matches);
  assign block_b = request_prio[1] && |(set_matches & mshr_block_b);
  assign block_c = request_prio[2] && |(set_matches & mshr_block_c);
  assign nest_b = request_prio[1] && |(set_matches & mshr_nest_b);
  assign nest_c = request_prio[2] && |(set_matches & mshr_nest_c);
  assign queue = |lower_matches && !block_b && !block_c && !nest_b && !nest_c;

  // A pre-empting C transaction stalls both the ordinary and BC handlers;
  // a pre-empting BC transaction stalls the ordinary handler for that set.
  always_comb begin
    schedule_stalled = '0;
    for (int slot = 0; slot < NormalMshrs; slot++) begin
      schedule_stalled[slot] =
          (mshr_valid[BcMshr] && mshr_set[slot] == mshr_set[BcMshr])
          || (mshr_valid[CMshr] && mshr_set[slot] == mshr_set[CMshr]);
    end
    schedule_stalled[BcMshr] = mshr_valid[CMshr] && mshr_set[BcMshr] == mshr_set[CMshr];
  end

  // BOOM picks the highest-priority matching reserved MSHR first. Under
  // ordinary operation there is at most one normal MSHR for a given set.
  assign secondary_a_valid = schedule_valid && secondary_queue_valid[int'(schedule_index)];
  assign secondary_b_valid = schedule_valid
                             && secondary_queue_valid[NumMshrs+int'(schedule_index)];
  assign secondary_c_valid = schedule_valid
                             && secondary_queue_valid[2*NumMshrs+int'(schedule_index)];
  assign secondary_may_pop = secondary_a_valid || secondary_b_valid || secondary_c_valid;
  assign secondary_pop_index = QueueBits'((secondary_c_valid ? 2 : secondary_b_valid ? 1 : 0)
                                                * NumMshrs + int'(schedule_index));
  assign bypass_matches = schedule_valid && lower_matches[int'(schedule_index)]
                          && ((secondary_c_valid || request_prio[2]) ? !secondary_c_valid
                              : (secondary_b_valid || request_prio[1]) ? !secondary_b_valid
                              : !secondary_a_valid);
  assign bypass = request_valid && queue && bypass_matches;
  assign bypass_queue = schedule_reload[int'(schedule_index)] && bypass_matches;
  assign reload_valid = schedule_valid && schedule_reload[int'(schedule_index)]
                        && (secondary_may_pop || bypass);
  assign reload_from_request = reload_valid && bypass;
  assign reload_needs_directory = reload_valid
                                  && mshr_tag[int'(schedule_index)]
                                         != (bypass ? request_tag : secondary_head_tag);
  assign secondary_pop_valid = reload_valid && secondary_may_pop && !bypass;
  // The directory has one read port. A queued request whose tag differs
  // from its current MSHR must own that read before a new allocation may.
  assign reload_directory_conflict = schedule_valid && schedule_reload[int'(schedule_index)]
                                     && secondary_may_pop
                                     && mshr_tag[int'(schedule_index)] != secondary_head_tag;

  always_comb begin
    queue_target = '0;
    queue_target_found = 1'b0;
    for (int slot = 0; slot < NormalMshrs; slot++) begin
      if (lower_matches[slot] && !queue_target_found) begin
        queue_target = MshrBits'(slot);
        queue_target_found = 1'b1;
      end
    end
    if (lower_matches[BcMshr]) queue_target = MshrBits'(BcMshr);
    if (lower_matches[CMshr]) queue_target = MshrBits'(CMshr);
  end

  always_comb begin
    free_found = 1'b0;
    free_index = '0;
    for (int slot = 0; slot < NumMshrs; slot++) begin
      if (free_matches[slot] && !free_found) begin
        free_found = 1'b1;
        free_index = MshrBits'(slot);
      end
    end
    allocate_index = nest_c ? MshrBits'(CMshr)
                   : nest_b ? MshrBits'(BcMshr) : free_index;
    request_ready = ((alloc && free_found)
                     || (nest_b && !mshr_valid[BcMshr] && !mshr_valid[CMshr])
                     || (nest_c && !mshr_valid[CMshr])) && !reload_directory_conflict
                    || (queue && (bypass_queue || secondary_push_ready));
    allocate_valid = request_valid && request_ready && (alloc || nest_b || nest_c);
    secondary_push_valid = request_valid && queue && !bypass_queue;
    secondary_push_index = QueueBits'((request_prio[2] ? 2 : request_prio[1] ? 1 : 0)
                                            * NumMshrs + int'(queue_target));
  end

  // The selected MSHR is lowest priority next time. As in BOOM, only
  // requests whose bank, directory, and output resources are ready compete.
  always_comb begin
    int candidate;
    schedule_valid = 1'b0;
    schedule_index = '0;
    schedule_onehot = '0;
    for (int offset = 1; offset <= NumMshrs; offset++) begin
      candidate = int'(last_schedule) + offset;
      if (candidate >= NumMshrs) candidate -= NumMshrs;
      if (!schedule_valid && schedule_request[candidate] && schedule_resources_ready[candidate]
          && !schedule_stalled[candidate]) begin
        schedule_valid = 1'b1;
        schedule_index = MshrBits'(candidate);
        schedule_onehot[candidate] = 1'b1;
      end
    end
  end

  always_ff @(posedge clock) begin
    if (reset) last_schedule <= MshrBits'(NumMshrs - 1);
    else if (schedule_valid) last_schedule <= schedule_index;
  end

`ifndef SYNTHESIS
  always_ff @(posedge clock) begin
    if (!reset && request_valid) assert ($onehot(request_prio));
  end
`endif
endmodule

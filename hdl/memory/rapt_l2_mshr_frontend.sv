// BOOM-sized miss admission and secondary replay fabric. The seven MSHR
// state machines supply their status and schedule requests; this module
// arbitrates them and keeps their 21 secondary queues in 33 shared entries.
// A secondary entry omits the set because its target MSHR already owns it.
module rapt_l2_mshr_frontend #(
    parameter int NumMshrs = 7,
    parameter int NumEntries = 33,
    parameter int SetBits = 10,
    parameter int TagBits = 18,
    parameter int PayloadBits = 64,
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
    input logic [PayloadBits-1:0] request_payload,
    input logic [NumMshrs-1:0] mshr_valid,
    input logic [SetBits-1:0] mshr_set[NumMshrs],
    input logic [TagBits-1:0] mshr_tag[NumMshrs],
    input logic [NumMshrs-1:0] mshr_block_b,
    input logic [NumMshrs-1:0] mshr_block_c,
    input logic [NumMshrs-1:0] mshr_nest_b,
    input logic [NumMshrs-1:0] mshr_nest_c,
    input logic [NumMshrs-1:0] schedule_request,
    input logic [NumMshrs-1:0] schedule_resources_ready,
    input logic [NumMshrs-1:0] schedule_reload,
    output logic allocate_valid,
    output logic [MshrBits-1:0] allocate_index,
    output logic schedule_valid,
    output logic [MshrBits-1:0] schedule_index,
    output logic [NumMshrs-1:0] schedule_onehot,
    output logic [NumMshrs-1:0] schedule_stalled,
    output logic reload_valid,
    output logic reload_from_request,
    output logic reload_needs_directory,
    output logic [TagBits-1:0] reload_tag,
    output logic [PayloadBits-1:0] reload_payload,
    output logic secondary_push_ready,
    output logic [3*NumMshrs-1:0] secondary_queue_valid
);
  if (PayloadBits < 1) $error("L2 MSHR request payload must be nonempty");

  logic secondary_push_valid, secondary_pop_valid;
  logic [QueueBits-1:0] secondary_push_index, secondary_pop_index;
  logic [TagBits+PayloadBits-1:0] secondary_head;
  logic [TagBits-1:0] secondary_head_tag;
  logic [PayloadBits-1:0] secondary_head_payload;

  assign {secondary_head_tag, secondary_head_payload} = secondary_head;
  assign reload_tag = reload_from_request ? request_tag : secondary_head_tag;
  assign reload_payload = reload_from_request ? request_payload : secondary_head_payload;

  rapt_l2_secondary_buffer #(
      .NumMshrs (NumMshrs),
      .NumEntries(NumEntries),
      .DataBits  (TagBits + PayloadBits)
  ) u_secondary (
      .clock,
      .reset,
      .push_valid (secondary_push_valid),
      .push_ready (secondary_push_ready),
      .push_index (secondary_push_index),
      .push_data  ({request_tag, request_payload}),
      .pop_valid  (secondary_pop_valid),
      .pop_index  (secondary_pop_index),
      .pop_data   (secondary_head),
      .queue_valid(secondary_queue_valid)
  );

  rapt_l2_mshr_scheduler #(
      .NumMshrs(NumMshrs),
      .SetBits  (SetBits),
      .TagBits  (TagBits)
  ) u_scheduler (
      .clock,
      .reset,
      .request_valid,
      .request_ready,
      .request_prio,
      .request_set,
      .request_tag,
      .mshr_valid,
      .mshr_set,
      .mshr_tag,
      .mshr_block_b,
      .mshr_block_c,
      .mshr_nest_b,
      .mshr_nest_c,
      .secondary_push_ready,
      .secondary_queue_valid,
      .secondary_head_tag,
      .secondary_push_valid,
      .secondary_push_index,
      .secondary_pop_valid,
      .secondary_pop_index,
      .allocate_valid,
      .allocate_index,
      .schedule_request,
      .schedule_resources_ready,
      .schedule_reload,
      .schedule_valid,
      .schedule_index,
      .schedule_onehot,
      .schedule_stalled,
      .reload_valid,
      .reload_from_request,
      .reload_needs_directory
  );
endmodule

// BOOM inclusive-cache Scheduler uses one shared 33-entry ListBuffer with
// three virtual request lists for each of its seven MSHRs (A, B and C).
// The queue is non-flowing: a push into an empty list becomes visible after
// the clock edge, and a full buffer cannot reuse a simultaneously popped slot.
module rapt_l2_secondary_buffer #(
    parameter int NumMshrs = 7,
    parameter int NumEntries = 33,
    parameter int DataBits = 64,
    parameter int NumQueues = 3 * NumMshrs,
    parameter int QueueBits = (NumQueues <= 1) ? 1 : $clog2(NumQueues),
    parameter int EntryBits = (NumEntries <= 1) ? 1 : $clog2(NumEntries)
) (
    input logic clock,
    input logic reset,
    input logic push_valid,
    output logic push_ready,
    input logic [QueueBits-1:0] push_index,
    input logic [DataBits-1:0] push_data,
    input logic pop_valid,
    input logic [QueueBits-1:0] pop_index,
    output logic [DataBits-1:0] pop_data,
    output logic [NumQueues-1:0] queue_valid
);
  if (NumMshrs < 3 || NumQueues != 3 * NumMshrs || NumEntries < NumMshrs || DataBits < 1)
    $error("invalid L2 secondary request buffer geometry");

  logic [NumEntries-1:0] used;
  logic [EntryBits-1:0] head[NumQueues];
  logic [EntryBits-1:0] tail[NumQueues];
  logic [EntryBits-1:0] next[NumEntries];
  logic [DataBits-1:0] data[NumEntries];
  logic [EntryBits-1:0] free_index;
  logic push_fire, pop_fire, pop_last;

  // BOOM's lowest-free one-hot allocator observes the pre-edge used bitmap.
  always_comb begin
    push_ready = 1'b0;
    free_index = '0;
    for (int entry = NumEntries - 1; entry >= 0; entry--) begin
      if (!used[entry]) begin
        push_ready = 1'b1;
        free_index = EntryBits'(entry);
      end
    end
  end

  assign push_fire = push_valid && push_ready;
  assign pop_fire = pop_valid;
  assign pop_last = head[pop_index] == tail[pop_index];
  assign pop_data = data[head[pop_index]];

  always_ff @(posedge clock) begin
    if (reset) begin
      used <= '0;
      queue_valid <= '0;
    end else begin
      if (pop_fire) begin
        used[head[pop_index]] <= 1'b0;
        if (pop_last) queue_valid[pop_index] <= 1'b0;
        // When the sole entry is popped and another request is appended to
        // the same list, the new entry becomes the head. The old next link
        // is overwritten at this edge and cannot be read for the new head.
        if (pop_last && push_fire && push_index == pop_index) head[pop_index] <= free_index;
        else head[pop_index] <= next[head[pop_index]];
      end
      if (push_fire) begin
        used[free_index] <= 1'b1;
        data[free_index] <= push_data;
        if (queue_valid[push_index]) next[tail[push_index]] <= free_index;
        else head[push_index] <= free_index;
        tail[push_index] <= free_index;
        queue_valid[push_index] <= 1'b1;
      end
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clock) begin
    if (!reset) begin
      assert (!push_valid || push_index < QueueBits'(NumQueues));
      assert (!pop_valid || (pop_index < QueueBits'(NumQueues) && queue_valid[pop_index]));
    end
  end
`endif
endmodule

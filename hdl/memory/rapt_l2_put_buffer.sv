// BOOM SinkA's non-flowing put ListBuffer: forty lists share forty beats.
// A list may hold multiple beats; the caller owns list allocation and retires
// a list after its last beat has been popped. A full pool does not accept a
// push merely because another list pops on the same edge.
module rapt_l2_put_buffer #(
    parameter int Xlen = 64,
    parameter int NumLists = 40,
    parameter int NumBeats = 40,
    parameter int ListBits = $clog2(NumLists),
    parameter int BeatBits = $clog2(NumBeats)
) (
    input logic clock,
    input logic reset,
    input logic push_valid,
    output logic push_ready,
    input logic [ListBits-1:0] push_list,
    input logic [Xlen-1:0] push_data,
    input logic [Xlen/8-1:0] push_mask,
    input logic push_last,
    input logic pop_valid,
    input logic [ListBits-1:0] pop_list,
    output logic [Xlen-1:0] pop_data,
    output logic [Xlen/8-1:0] pop_mask,
    output logic pop_last,
    output logic [NumLists-1:0] list_valid
);
  if (!(Xlen inside {32, 64}) || NumLists < 2 || NumBeats < NumLists)
    $error("invalid L2 put-buffer geometry");

  typedef struct packed {
    logic [Xlen-1:0] data;
    logic [Xlen/8-1:0] mask;
    logic last;
  } beat_t;

  logic [NumBeats-1:0] used;
  logic [BeatBits-1:0] head[NumLists];
  logic [BeatBits-1:0] tail[NumLists];
  logic [BeatBits-1:0] next[NumBeats];
  beat_t beat[NumBeats];
  logic [BeatBits-1:0] free_index;
  logic push_fire, pop_last_entry;

  // BOOM's lowest-free allocator uses the pre-edge occupancy bitmap.
  always_comb begin
    push_ready = 1'b0;
    free_index = '0;
    for (int entry = NumBeats - 1; entry >= 0; entry--) begin
      if (!used[entry]) begin
        push_ready = 1'b1;
        free_index = BeatBits'(entry);
      end
    end
  end

  assign push_fire = push_valid && push_ready;
  assign pop_last_entry = head[pop_list] == tail[pop_list];
  assign {pop_data, pop_mask, pop_last} = beat[head[pop_list]];

  always_ff @(posedge clock) begin
    if (reset) begin
      used <= '0;
      list_valid <= '0;
    end else begin
      if (pop_valid) begin
        used[head[pop_list]] <= 1'b0;
        if (pop_last_entry) list_valid[pop_list] <= 1'b0;
        if (pop_last_entry && push_fire && push_list == pop_list) head[pop_list] <= free_index;
        else head[pop_list] <= next[head[pop_list]];
      end
      if (push_fire) begin
        used[free_index] <= 1'b1;
        beat[free_index] <= {push_data, push_mask, push_last};
        if (list_valid[push_list]) next[tail[push_list]] <= free_index;
        else head[push_list] <= free_index;
        tail[push_list] <= free_index;
        list_valid[push_list] <= 1'b1;
      end
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clock) begin
    if (!reset) begin
      assert (!push_valid || int'(push_list) < NumLists);
      assert (!pop_valid || (int'(pop_list) < NumLists && list_valid[pop_list]));
    end
  end
`endif
endmodule

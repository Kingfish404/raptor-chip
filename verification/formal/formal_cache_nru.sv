// A stable symbolic set represents every cache set. The independent model
// tracks individual way marks and counts marks other than the touched way.
module formal_cache_nru #(
    parameter int Ways = 8,
    parameter int SetBits = 2,
    parameter int ReadPorts = 2,
    parameter int WayBits = $clog2(Ways),
    parameter bit GuidedCover = 1'b0
) (
    input logic clock,
    reset,
    invalidate,
    input logic [SetBits-1:0] watched_set,
    input logic [SetBits-1:0] read_set[ReadPorts],
    input logic update_valid,
    input logic [SetBits-1:0] update_set,
    input logic [WayBits-1:0] update_way
);
  logic [WayBits-1:0] victim[ReadPorts];
  rapt_cache_nru #(
      .Ways(Ways),
      .SetBits(SetBits),
      .ReadPorts(ReadPorts)
  ) dut (
      .*
  );
  logic [Ways-1:0] marked;
  logic [Ways-1:0] next_marked;
  int other_marks;
  always_comb begin
    other_marks = 0;
    for (int way = 0; way < Ways; way++) if (way != int'(update_way) && marked[way]) other_marks++;
    next_marked = marked;
    if (other_marks == Ways - 1) next_marked = '0;
    next_marked[update_way] = 1'b1;
  end
  logic [WayBits-1:0] expected;
  logic found;
  always_comb begin
    expected = '0;
    found = 1'b0;
    for (int way = 0; way < Ways; way++) begin
      if (!found && !marked[way]) begin
        found = 1'b1;
        expected = WayBits'(way);
      end
    end
  end
  logic past_valid = 0;
  logic [SetBits-1:0] previous_set;
  logic seen_update = 0, seen_rollover = 0, seen_invalidate = 0;
  if (GuidedCover) begin : g_cover_stimulus
    // Reachability uses a legal external stimulus, separate from the fully
    // unconstrained safety proof. No DUT state, output or progress is assumed.
    logic [$clog2(Ways+8)-1:0] step = '0;
    always_ff @(posedge clock) begin
      if (reset) step <= '0;
      else if (int'(step) < Ways + 4) step <= step + 1'b1;
      if (past_valid) begin
        assume (!reset);
        for (int p = 0; p < ReadPorts; p++) assume (read_set[p] == watched_set);
        if (int'(step) < Ways) begin
          assume (update_valid && !invalidate && update_set == watched_set
              && update_way == WayBits'(step));
        end else if (int'(step) == Ways + 1) begin
          assume (!update_valid && invalidate);
        end else if (int'(step) == Ways + 2) begin
          assume (update_valid && !invalidate && update_set == (watched_set ^ SetBits'(1)));
        end else assume (!update_valid && !invalidate);
      end
    end
  end
  always_ff @(posedge clock) begin
    if (!past_valid) assume (reset);
    if (past_valid) assume (watched_set == previous_set);
    previous_set <= watched_set;
    past_valid <= 1'b1;
    if (reset || invalidate) marked <= '0;
    else if (update_valid && update_set == watched_set) marked <= next_marked;
    if (reset) begin
      seen_update <= 0;
      seen_rollover <= 0;
      seen_invalidate <= 0;
    end else begin
      if (update_valid && !invalidate && update_set == watched_set) begin
        seen_update <= 1;
        if (other_marks == Ways - 1) seen_rollover <= 1;
      end
      if (invalidate && seen_update) seen_invalidate <= 1;
    end
    if (past_valid) begin
      state_correspondence :
      assert (dut.initialized[watched_set] ? dut.recent[watched_set] == marked : marked == '0);
      cold_way_exists : assert (found);
    end
    epoch_rollover : cover (past_valid && seen_rollover && !reset && !invalidate);
    invalidate_after_touch : cover (past_valid && seen_invalidate && marked == '0 && !reset);
    other_set_update :
    cover (past_valid && seen_update && update_valid
        && update_set != watched_set && !reset && !invalidate);
  end
  for (genvar p = 0; p < ReadPorts; p++) begin : g_read
    always_ff @(posedge clock) begin
      if (past_valid && read_set[p] == watched_set) begin
        lowest_cold_way : assert (victim[p] == expected);
      end
      port_activation :
      cover (past_valid && seen_update && read_set[p] == watched_set && !reset && !invalidate);
    end
  end
endmodule

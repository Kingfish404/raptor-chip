// Resource qualification is independent of earlier acceptance decisions.
// If every older slot passed, its demand rank equals its accepted rank. If an
// older slot did not pass, the prefix blocks this slot regardless of its rank.
module rapt_rename_admit #(
    parameter int Width = 2,
    localparam int RankBits = Width > 1 ? $clog2(Width) : 1
) (
    input logic enable,
    input logic valid[Width],
    downstream_ready[Width],
    input logic destination_needed[Width],
    checkpoint_needed[Width],
    input logic physical_found[Width],
    checkpoint_found[Width],
    output logic ready[Width],
    fire[Width],
    output logic checkpoint_stall
);
  logic [Width-1:0] destinations, checkpoints, passes, checkpoint_blocked;
  for (genvar s = 0; s < Width; s++) begin : g_slot
    logic [RankBits-1:0] physical_rank, checkpoint_rank;
    logic physical_ok, checkpoint_ok, older_passed;
    assign destinations[s] = destination_needed[s];
    assign checkpoints[s] = checkpoint_needed[s];
    if (s == 0) begin : g_first
      assign physical_rank = '0;
      assign checkpoint_rank = '0;
      assign older_passed = enable;
    end else begin : g_later
      assign physical_rank = RankBits'($countones(destinations[s-1:0]));
      assign checkpoint_rank = RankBits'($countones(checkpoints[s-1:0]));
      assign older_passed = enable && (&passes[s-1:0]);
    end
    assign physical_ok = !destination_needed[s] || physical_found[physical_rank];
    assign checkpoint_ok = !checkpoint_needed[s] || checkpoint_found[checkpoint_rank];
    assign passes[s] = valid[s] && downstream_ready[s] && physical_ok && checkpoint_ok;
    assign ready[s] = older_passed && downstream_ready[s] && physical_ok && checkpoint_ok;
    assign fire[s] = valid[s] && ready[s];
    // Only the first ordered, checkpoint-exclusive admission loss is counted.
    assign checkpoint_blocked[s] = older_passed && valid[s] && downstream_ready[s]
        && physical_ok && checkpoint_needed[s] && !checkpoint_ok;
  end
  assign checkpoint_stall = |checkpoint_blocked;
  if (Width < 1) begin : g_invalid
    $error("Invalid rapt_rename_admit configuration");
  end
endmodule

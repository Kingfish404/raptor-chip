// Independent serial accepted-rank oracle matching the original RNU admission.
module formal_rename_admit #(
    parameter int Width = 3
) (
    input logic enable,
    input logic valid[Width],
    downstream_ready[Width],
    input logic destination_needed[Width],
    checkpoint_needed[Width],
    input logic physical_found[Width],
    checkpoint_found[Width],
    output logic correct
);
  logic ready[Width], fire[Width], checkpoint_stall;
  logic reference_ready[Width], reference_fire[Width], reference_stall, prefix;
  int physical_rank, checkpoint_rank;
  rapt_rename_admit #(.Width(Width)) dut (.*);
  always_comb begin
    physical_rank = 0;
    checkpoint_rank = 0;
    prefix = enable;
    reference_stall = 0;
    for (int s = 0; s < Width; s++) begin
      reference_stall |= prefix && valid[s] && downstream_ready[s]
          && (!destination_needed[s] || physical_found[physical_rank])
          && checkpoint_needed[s] && !checkpoint_found[checkpoint_rank];
      reference_ready[s] = prefix && downstream_ready[s]
          && (!destination_needed[s] || physical_found[physical_rank])
          && (!checkpoint_needed[s] || checkpoint_found[checkpoint_rank]);
      reference_fire[s] = valid[s] && reference_ready[s];
      if (reference_fire[s] && destination_needed[s]) physical_rank++;
      if (reference_fire[s] && checkpoint_needed[s]) checkpoint_rank++;
      prefix &= reference_fire[s];
    end
    correct = ready == reference_ready && fire == reference_fire
        && checkpoint_stall == reference_stall;
  end
endmodule

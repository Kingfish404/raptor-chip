`include "rapt.svh"
`include "rapt_if.svh"
module rapt_dispatch_iq_adapter #(
    parameter type CapacityT = rapt_pkg::dispatch_capacity_t,
    parameter type GrantT = rapt_pkg::dispatch_grant_t,
    parameter int Width = rapt_pkg::DispatchWidth
) (
    dpu_iq_if.top queue,
    output CapacityT capacity,
    input GrantT grant
);
  for (genvar s = 0; s < Width; s++) begin : g_slot
    assign capacity.ready[s] = queue.free_found[s];
    assign capacity.free_index[s] = queue.free_idx[s];
    assign queue.accept[s] = grant.accept[s];
    assign queue.rs_idx[s] = grant.index[s];
  end
endmodule

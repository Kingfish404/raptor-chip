`include "rapt.svh"
`include "rapt_if.svh"
module rapt_dispatch_ioq_adapter #(
    parameter type CapacityT = rapt_pkg::dispatch_capacity_t,
    parameter type GrantT = rapt_pkg::dispatch_grant_t,
    parameter int Width = rapt_pkg::DispatchWidth
) (
    dpu_ioq_if.top queue,
    output CapacityT capacity,
    input GrantT grant
);
  for (genvar s = 0; s < Width; s++) begin : g_slot
    assign capacity.ready[s] = queue.ready[s];
    assign capacity.free_index[s] = '0;
    assign queue.accept[s] = grant.accept[s];
  end
endmodule

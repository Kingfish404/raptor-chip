`include "rapt.svh"

// Compare replacement policies with identical one-update/two-query ports.
module rapt_l1d_policy_syn_top #(
    parameter int Ways = `RAPT_L1D_WAYS,
    parameter int SetBits = `RAPT_L1D_LEN,
    parameter bit Nru = `RAPT_L1D_NRU != 0,
    parameter int WayBits = $clog2(Ways)
) (
    input logic clock,
    input logic reset,
    input logic invalidate,
    input logic [SetBits-1:0] read_set[2],
    output wire [WayBits-1:0] victim[2],
    input logic update_valid,
    input logic [SetBits-1:0] update_set,
    input logic [WayBits-1:0] update_way
);
  if (Nru) begin : g_nru
    rapt_cache_nru #(
        .Ways(Ways),
        .SetBits(SetBits)
    ) u_policy (
        .*
    );
  end else begin : g_plru
    wire [SetBits-1:0] sets[1];
    wire [WayBits-1:0] ways[1];
    assign sets[0] = update_set;
    assign ways[0] = update_way;
    rapt_cache_plru #(
        .Ways(Ways),
        .SetBits(SetBits),
        .UpdatePorts(1)
    ) u_policy (
        .clock(clock),
        .reset(reset),
        .invalidate(invalidate),
        .read_set(read_set),
        .victim(victim),
        .update_valid(update_valid),
        .update_set(sets),
        .update_way(ways)
    );
  end
endmodule

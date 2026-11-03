`include "rapt_if.svh"
module rapt_arty_prf_probe (
    input logic clock,
    input logic reset,
    input logic write_i,
    input logic [5:0] address_i,
    input logic [31:0] data_i,
    output logic valid_o,
    output logic [31:0] data_o
);
  rapt_pkg::completion_t completion[rapt_pkg::CompletionPorts];
  exu_prf_if reads ();
  rou_cmu_if commit_bus ();
  cmu_bcast_if broadcast ();
  logic [5:0] map_snapshot[32];
  logic [31:0] unused_rf[32], unused_map[32];
  logic [31:0] extra_value[1];
  logic extra_valid[1];
  always_comb begin
    for (int p = 0; p < rapt_pkg::CompletionPorts; p++) completion[p] = '0;
    completion[0].valid = write_i;
    completion[0].rd = 5'd2;
    completion[0].prd = address_i;
    completion[0].result = data_i;
  end
  for (genvar r = 0; r < 32; r++) begin : g_map
    assign map_snapshot[r] = 6'(r);
  end
  assign reads.pr1[0] = address_i;
  assign reads.pr2[0] = '0;
  assign valid_o = reads.pv1_valid[0];
  assign data_o = reads.pv1[0];
  assign commit_bus.slot[0] = '0;
  assign broadcast.flush_pipe = 1'b0;
  rapt_prf u_prf (
      .completion(completion),
      .clock(clock),
      .reset(reset),
      .extra_address('{6'b0}),
      .extra_value(extra_value),
      .extra_valid(extra_valid),
      .prf_rd(reads),
      .rou_cmu(commit_bus),
      .cmu_bcast(broadcast),
      .map_snapshot(map_snapshot),
      .rat_snapshot(map_snapshot),
      .rf(unused_rf),
      .rf_map(unused_map),
      .dbg_we_i(1'b0),
      .dbg_addr_i(5'b0),
      .dbg_wdata_i('0),
      .dbg_rdata_o()
  );
endmodule

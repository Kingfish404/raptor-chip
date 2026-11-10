`timescale 1ns / 1ps
module tb_native_monitor #(
    parameter int BaseSkewNs = 18
);
  logic clock = 0, reset_n = 0, cs_n = 1, ck = 0;
  logic source_ds = 0;
  logic [7:0] source_dq = 0, source_oe = 0;
  wire receiver_ds;
  wire [7:0] receiver_dq, receiver_oe;
  int signed lane_min[8], lane_max[8];
  int unsigned lane_count[8], rise_count[8], fall_count[8];
  int unsigned core_period[3], timing_ps[12];
  always #50 clock = !clock;
  assign #91 receiver_ds = source_ds;
  for (genvar lane = 0; lane < 8; lane++) begin : g_wire
    assign #(91 + BaseSkewNs + lane) receiver_dq[lane] = source_dq[lane];
    assign #(91 + BaseSkewNs + lane) receiver_oe[lane] = source_oe[lane];
  end
  rapt_native_monitor u_monitor (
      .core_clock_i(clock),
      .reset_n_i(reset_n),
      .cs_n_i(cs_n),
      .ck_i(ck),
      .source_ds_i(source_ds),
      .source_dq_i(source_dq),
      .source_oe_i(source_oe),
      .receiver_ds_i(receiver_ds),
      .receiver_dq_i(receiver_dq),
      .receiver_oe_i(receiver_oe),
      .host_oe_i(8'b0),
      .target_dq_i(8'b0),
      .target_host_oe_i(8'b0),
      .lane_min_ps_o(lane_min),
      .lane_max_ps_o(lane_max),
      .lane_count_o(lane_count),
      .lane_rise_count_o(rise_count),
      .lane_fall_count_o(fall_count),
      .core_period_ps_o(core_period),
      .timing_ps_o(timing_ps)
  );
  task automatic frame;
    cs_n = 0;
    #800;
    source_oe = 8'hff;
    for (int byte_index = 0; byte_index < 20; byte_index++) begin
      source_dq = ~source_dq;
      source_ds = ~source_ds;
      ck = ~ck;
      #800;
    end
    source_oe = 0;
    cs_n = 1;
    #400;
  endtask
  initial begin
    #200;
    reset_n = 1;
    frame();
    // More than 2^31 ps: the previous monitor overflowed this minimum candidate.
    #3_000_000;
    frame();
    for (int lane = 0; lane < 8; lane++) begin
      if (lane_min[lane] != 1000 * (BaseSkewNs + lane)
          || lane_max[lane] != 1000 * (BaseSkewNs + lane)
          || rise_count[lane] == 0 || fall_count[lane] == 0)
        $fatal(1, "Native monitor lane %0d measured incorrectly", lane);
    end
    if (core_period[0] != 100000 || core_period[1] != 100000)
      $fatal(1, "Native monitor core period incorrect");
    $display("NATIVE_MONITOR_PASS: signed per-lane arrivals, both DS edges, long idle gap");
    $finish;
  end
endmodule

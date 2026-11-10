`timescale 1ns / 1ps
// Measure arrivals at the receiver inputs, including the existing per-lane wire delays.
module rapt_native_monitor #(
    parameter int unsigned CoreClockHz = 10_000_000
) (
    input wire core_clock_i,
    input wire reset_n_i,
    input wire cs_n_i,
    input wire ck_i,
    input wire source_ds_i,
    input wire [7:0] source_dq_i,
    input wire [7:0] source_oe_i,
    input wire receiver_ds_i,
    input wire [7:0] receiver_dq_i,
    input wire [7:0] receiver_oe_i,
    input wire [7:0] host_oe_i,
    input wire [7:0] target_dq_i,
    input wire [7:0] target_host_oe_i,
    output int signed lane_min_ps_o[8],
    output int signed lane_max_ps_o[8],
    output int unsigned lane_count_o[8],
    output int unsigned lane_rise_count_o[8],
    output int unsigned lane_fall_count_o[8],
    output int unsigned core_period_ps_o[3],
    output int unsigned timing_ps_o[12]
);
  localparam int MaxSkewPs = 250_000_000_000 / CoreClockHz;
  logic previous_source_ds = 0, previous_receiver_ds = 0;
  logic previous_ck = 0, previous_cs = 1, previous_reset = 0;
  logic [7:0] previous_source_byte = 0, previous_receiver_dq = 0;
  logic [7:0] previous_receiver_oe = 0, previous_host_oe = 0;
  logic [7:0] previous_target_dq = 0, previous_target_host_oe = 0;
  logic [7:0] previous_source_oe = 0, expected_byte = 0, pending = 0;
  bit previous_byte_valid = 0, epoch_valid = 0, ds_arrived = 0, ds_rising = 0;
  bit dq_arrived[8];
  realtime dq_arrival[8];
  realtime ds_arrival = 0, last_ck = 0, last_capture = 0;
  realtime last_tx_change = 0, last_host_release = 0, last_target_release = 0;
  realtime last_cs_fall = 0, last_cs_rise = 0, reset_assertion = 0;

  realtime previous_core_edge = 0;

  // The core-period measurement has a separate writer from the link measurements.
  always @(posedge core_clock_i) begin
    int unsigned period_ps;
    if (previous_core_edge != 0) begin
      period_ps = int'($floor(($realtime - previous_core_edge) * 1000.0 + 0.5));
      if (period_ps < core_period_ps_o[0]) core_period_ps_o[0] = period_ps;
      if (period_ps > core_period_ps_o[1]) core_period_ps_o[1] = period_ps;
      core_period_ps_o[2]++;
    end
    previous_core_edge = $realtime;
  end

  task automatic record_min(input int metric, input realtime elapsed);
    int value_ps;
    if (elapsed < 0) $fatal(1, "Native monitor observed negative timing interval");
    // Long power-up/recovery gaps cannot reduce a sub-millisecond minimum.
    if (elapsed * 1000.0 < 2_147_483_647.0) begin
      value_ps = int'($floor(elapsed * 1000.0 + 0.5));
      if (32'(value_ps) < timing_ps_o[metric]) timing_ps_o[metric] = 32'(value_ps);
    end
  endtask

  initial begin
    for (int lane = 0; lane < 8; lane++) begin
      lane_min_ps_o[lane] = 32'sh7fffffff;
      lane_max_ps_o[lane] = -32'sh7fffffff;
      lane_count_o[lane] = 0;
      lane_rise_count_o[lane] = 0;
      lane_fall_count_o[lane] = 0;
      dq_arrived[lane] = 0;
      dq_arrival[lane] = 0;
    end
    for (int metric = 0; metric < 12; metric++) timing_ps_o[metric] = 32'h7fffffff;
    core_period_ps_o[0] = 32'h7fffffff;
    core_period_ps_o[1] = 0;
    core_period_ps_o[2] = 0;
    // Metrics 1/2 are CK maximum interval and observation count, respectively.
    timing_ps_o[1] = 0;
    timing_ps_o[2] = 0;
  end

  always @(reset_n_i or cs_n_i or ck_i or source_ds_i or source_dq_i or source_oe_i
           or receiver_ds_i or receiver_dq_i or receiver_oe_i or host_oe_i
           or target_dq_i or target_host_oe_i) begin : observe_pins
    int signed   skew_ps;
    int unsigned interval_ps;
    if ((host_oe_i & receiver_oe_i) != 0)
      $fatal(1, "Native host and delayed target ownership overlap");
    if ((target_host_oe_i & source_oe_i) != 0)
      $fatal(1, "Native host and target ownership overlap at target pins");
    if (!reset_n_i) begin
      epoch_valid = 0;
      pending = 0;
      previous_byte_valid = 0;
      last_ck = 0;
      last_capture = 0;
      if (previous_reset) reset_assertion = $realtime;
    end else begin
      if (!previous_reset) record_min(11, $realtime - reset_assertion);
      if (source_ds_i != previous_source_ds && source_oe_i == 8'hff && !cs_n_i) begin
        epoch_valid = 1;
        expected_byte = source_dq_i;
        pending = previous_byte_valid ? source_dq_i ^ previous_source_byte : 8'hff;
        previous_source_byte = source_dq_i;
        previous_byte_valid = 1;
        ds_arrived = 0;
        for (int lane = 0; lane < 8; lane++) dq_arrived[lane] = 0;
      end
      if (source_oe_i == 0) begin
        epoch_valid = 0;
        previous_byte_valid = 0;
      end
      if (epoch_valid) begin
        if (receiver_ds_i != previous_receiver_ds) begin
          ds_arrival = $realtime;
          ds_arrived = 1;
          ds_rising  = receiver_ds_i;
        end
        for (int lane = 0; lane < 8; lane++) begin
          if (pending[lane] && receiver_oe_i[lane]
              && (receiver_dq_i[lane] != previous_receiver_dq[lane]
                  || !previous_receiver_oe[lane])
              && receiver_dq_i[lane] == expected_byte[lane]) begin
            dq_arrival[lane] = $realtime;
            dq_arrived[lane] = 1;
          end
          if (pending[lane] && ds_arrived && dq_arrived[lane]) begin
            skew_ps = int'($floor((dq_arrival[lane] - ds_arrival) * 1000.0 + 0.5));
            if (skew_ps < lane_min_ps_o[lane]) lane_min_ps_o[lane] = skew_ps;
            if (skew_ps > lane_max_ps_o[lane]) lane_max_ps_o[lane] = skew_ps;
            lane_count_o[lane]++;
            if (ds_rising) lane_rise_count_o[lane]++;
            else lane_fall_count_o[lane]++;
            pending[lane] = 0;
            if (skew_ps < -MaxSkewPs || skew_ps > MaxSkewPs)
              $fatal(1, "Native lane %0d actual DQ-DS skew %0d ps exceeds envelope", lane, skew_ps);
          end
        end
      end
      if (target_host_oe_i == 0 && previous_target_host_oe != 0) last_host_release = $realtime;
      if (source_oe_i == 8'hff && previous_source_oe != 8'hff && last_host_release != 0)
        record_min(5, $realtime - last_host_release);
      if (receiver_oe_i == 0 && previous_receiver_oe != 0) last_target_release = $realtime;
      if (host_oe_i == 8'hff && previous_host_oe != 8'hff && last_target_release != 0)
        record_min(6, $realtime - last_target_release);
      if (cs_n_i != previous_cs) begin
        if (!cs_n_i) begin
          last_cs_fall = $realtime;
          if (last_cs_rise != 0) record_min(10, $realtime - last_cs_rise);
        end else begin
          last_cs_rise = $realtime;
          if (last_ck != 0) record_min(9, $realtime - last_ck);
          last_ck = 0;
          last_capture = 0;
        end
      end
      if (target_dq_i != previous_target_dq || target_host_oe_i != previous_target_host_oe) begin
        if (previous_target_host_oe == 8'hff && last_capture != 0)
          record_min(4, $realtime - last_capture);
        if (target_host_oe_i == 8'hff) last_tx_change = $realtime;
      end
      if (ck_i != previous_ck && !cs_n_i) begin
        if (last_ck != 0) begin
          interval_ps = int'($floor(($realtime - last_ck) * 1000.0 + 0.5));
          record_min(0, $realtime - last_ck);
          if (interval_ps > timing_ps_o[1]) timing_ps_o[1] = interval_ps;
          timing_ps_o[2]++;
        end else record_min(8, $realtime - last_cs_fall);
        last_ck = $realtime;
        if (target_host_oe_i == 8'hff) begin
          record_min(3, $realtime - last_tx_change);
          last_capture = $realtime;
        end
      end
    end
    previous_source_ds = source_ds_i;
    previous_receiver_ds = receiver_ds_i;
    previous_source_oe = source_oe_i;
    previous_receiver_dq = receiver_dq_i;
    previous_receiver_oe = receiver_oe_i;
    previous_host_oe = host_oe_i;
    previous_target_host_oe = target_host_oe_i;
    previous_target_dq = target_dq_i;
    previous_ck = ck_i;
    previous_cs = cs_n_i;
    previous_reset = reset_n_i;
  end
endmodule

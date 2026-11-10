`timescale 1ns / 1ps
// Check the last VALID DS edge at the pins, independently of PHY receive state.
// Later target data/strobe edges are dummy edges (JESD251D Figure 37).
module tb_xspi_tail #(
    parameter bit Late = 0,
    parameter int HalfPeriod = 10,
    parameter realtime ClockHalfNs = 5.0,
    parameter realtime ReturnDelayNs = -1.0,
    parameter realtime DqSkewNs = 0.0
);
  localparam realtime CkPeriodNs = 4.0 * HalfPeriod * ClockHalfNs;
  localparam realtime ReturnNs = ReturnDelayNs >= 0 ? ReturnDelayNs
      : (Late ? 0.625 * CkPeriodNs : 0.05 * CkPeriodNs);
  logic clock = 0, reset = 1, request = 0, missing = 0;
  always #(ClockHalfNs) clock = !clock;
  logic done, error, mismatch, sclk, cs_n;
  logic [127:0] data;
  logic [7:0] tx, oe, dq;
  logic [7:0] target_dq = 0;
  logic target_ds = 0;
  logic [7:0] returned_dq;
  logic returned_ds;
  // Transport delays preserve every edge even beyond one CK half period.
  always @(target_dq) returned_dq <= #(ReturnNs + 1.0 + DqSkewNs) target_dq;
  always @(target_ds) returned_ds <= #(ReturnNs + 1) target_ds;
  always_comb begin
    for (int i = 0; i < 8; i++) dq[i] = oe[i] ? tx[i] : returned_dq[i];
  end
  rapt_xspi_frame #(
      .HalfPeriod(HalfPeriod),
      .ReadTimeoutCycles(1000)
  ) dut (
      .clock,
      .reset,
      .req_i(request),
      .octal_i(1'b1),
      .header_i(48'hfdfd00000000),
      .header_bytes_i(3'd6),
      .latency_i(6'd16),
      .transmit_i(1'b0),
      .bytes_i(13'd4),
      .write_i(32'b0),
      .verify_i(1'b0),
      .erase_i(1'b0),
      .done_o(done),
      .error_o(error),
      .mismatch_o(mismatch),
      .data_o(data),
      .sclk_o(sclk),
      .cs_n_o(cs_n),
      .dq_o(tx),
      .dq_oe_o(oe),
      .dq_i(dq),
      .ds_i(returned_ds)
  );

  int target_edges = 0, strobe_edges = 0, completed = 0;

  // Observe actual output edges; a test parameter must reach the PHY leaf.
  realtime previous_edge_at = 0, previous_rise_at = 0;
  int measured_halves = 0, measured_periods = 0;
  realtime observed_half_ns = 0, observed_period_ns = 0;
  always @(negedge cs_n) begin
    previous_edge_at = 0;
    previous_rise_at = 0;
  end
  always @(sclk) begin
    if (!reset && !cs_n) begin
      if (previous_edge_at != 0) begin
        if ($realtime - previous_edge_at != 2.0 * HalfPeriod * ClockHalfNs)
          $fatal(
              1,
              "Actual CK half-period mismatch: got=%0f want=%0f",
              $realtime - previous_edge_at,
              2.0 * HalfPeriod * ClockHalfNs
          );
        observed_half_ns = $realtime - previous_edge_at;
        measured_halves++;
      end
      previous_edge_at = $realtime;
      if (sclk) begin
        if (previous_rise_at != 0) begin
          if ($realtime - previous_rise_at != 4.0 * HalfPeriod * ClockHalfNs)
            $fatal(1, "Actual CK full-period mismatch");
          observed_period_ns = $realtime - previous_rise_at;
          measured_periods++;
        end
        previous_rise_at = $realtime;
      end
    end
  end

  bit previous_cs = 1, previous_ck = 0;
  realtime last_valid = 0;
  bit last_valid_ck = 0;
  always @(sclk or cs_n) begin
    if (previous_cs && !cs_n) begin
      target_edges = 0;
      target_ds = 0;
      target_dq = 0;
    end else if (!cs_n && previous_ck != sclk) begin
      target_edges++;
      // Six header bytes, then sixteen complete latency cycles.
      if (target_edges > 38) begin
        if (oe != 0) $fatal(1, "Host drives during target data");
        target_dq = 8'(target_edges - 39);
        if (!missing) target_ds = !target_ds;
      end
    end
    previous_cs = cs_n;
    previous_ck = sclk;
  end
  always @(negedge cs_n) begin
    strobe_edges = 0;
    last_valid = 0;
  end
  always @(returned_ds) begin
    if (!cs_n && !missing) begin
      strobe_edges++;
      // This independent transaction requests exactly four valid data bytes.
      if (strobe_edges == 4) begin
        if (returned_ds !== 0) $fatal(1, "Last valid word did not end DS low");
        last_valid = $realtime;
        last_valid_ck = sclk;
      end
    end
  end
  always @(posedge cs_n) begin
    if (!reset) begin
      if (sclk) $fatal(1, "CS changes while CK high");
      if (!missing) begin
        if (last_valid == 0 || $realtime - last_valid < 0.8 * CkPeriodNs)
          $fatal(1, "DS-to-CS hold < 0.8 CK: %0f", $realtime - last_valid);
        if (last_valid_ck != Late) $fatal(1, "Requested DS/CK phase was not exercised");
        completed++;
      end
    end
  end
  task automatic transact;
    @(negedge clock);
    request = 1;
    @(negedge clock);
    request = 0;
    while (!done) @(negedge clock);
    @(negedge clock);
  endtask
  initial begin
    repeat (5) @(negedge clock);
    reset = 0;
    #(ReturnNs + 20);
    transact();
    $display("CK observed before data check: HP=%0d half_ns=%0f period_ns=%0f", HalfPeriod,
             observed_half_ns, observed_period_ns);
    if (error || mismatch || data[31:0] != 32'h03020100 || completed != 1)
      $fatal(1, "Last byte/tail error=%b data=%h completed=%0d", error, data, completed);
    missing = 1;
    transact();
    if (!error || !cs_n || sclk) $fatal(1, "Missing DS did not terminate safely");
    if (measured_halves == 0 || measured_periods == 0) $fatal(1, "CK monitor was vacuous");
    $display("CK measured: HP=%0d core_half_ns=%0f half_ns=%0f period_ns=%0f", HalfPeriod,
             ClockHalfNs, 2.0 * HalfPeriod * ClockHalfNs, 4.0 * HalfPeriod * ClockHalfNs);
    $display("PASS: independent xSPI tail CKphase=%0d delay=%0f hold>=0.8CK, missing DS", Late,
             ReturnNs);
    $finish;
  end
  initial begin
    #(10_000 * ClockHalfNs);
    $fatal(1, "Tail test timeout");
  end
endmodule

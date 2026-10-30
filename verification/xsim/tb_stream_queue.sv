`include "rapt.svh"
`include "stream_queue_shadow.sv"

module stream_queue_case #(
    parameter int Depth = 7,
    InWidth = 3,
    OutWidth = 4,
    parameter bit ReclaimSameCycle = 1'b1
) (
    input  logic clock,
    output logic done
);
  logic reset = 1, flush = 0;
  typedef struct packed {
    logic [31:0] tag;
    logic [31:0] inverse_tag;
    logic [32:0] sequence_id;
  } payload_t;
  payload_t in_data[InWidth], out_data[OutWidth], shadow_data[OutWidth];
  logic in_valid[InWidth], in_ready[InWidth], out_valid[OutWidth], out_ready[OutWidth];
  logic shadow_ready[InWidth], shadow_valid[OutWidth];
  logic [$clog2(Depth+1)-1:0] occupancy;
  logic [$clog2(Depth+1)-1:0] shadow_occupancy;
  payload_t model[$], expected;
  int unsigned sequence_id = 1;
  logic [31:0] random_state = 32'h51a7c001;
  int pushes, pops, simultaneous = 0, full_seen = 0, flush_seen = 0;
  rapt_stream_queue #(
      .ItemT(payload_t),
      .Depth(Depth),
      .InWidth(InWidth),
      .OutWidth(OutWidth),
      .ReclaimSameCycle(ReclaimSameCycle)
  ) dut (
      .*
  );
  stream_queue_shadow #(
      .ItemT(payload_t),
      .Depth(Depth),
      .InWidth(InWidth),
      .OutWidth(OutWidth),
      .ReclaimSameCycle(ReclaimSameCycle)
  ) shadow (
      .clock,
      .reset,
      .flush,
      .in_data,
      .in_valid,
      .in_ready(shadow_ready),
      .out_data(shadow_data),
      .out_valid(shadow_valid),
      .out_ready,
      .occupancy(shadow_occupancy)
  );
  // Check settled outputs on both sides of the accepting edge. The first
  // post-edge check catches empty-queue enqueue visibility without a bypass.
  always @(posedge clock or negedge clock) begin
    #1;
    `RAPT_SVA_IMM(STREAM_SHADOW_OCCUPANCY, occupancy == shadow_occupancy)
    for (int s = 0; s < InWidth; s++) begin
      `RAPT_SVA_IMM(STREAM_SHADOW_READY, in_ready[s] == shadow_ready[s])
    end
    for (int s = 0; s < OutWidth; s++) begin
      `RAPT_SVA_IMM(STREAM_SHADOW_VALID, out_valid[s] == shadow_valid[s])
      if (out_valid[s]) begin
        `RAPT_SVA_IMM(STREAM_SHADOW_PAYLOAD, out_data[s] == shadow_data[s])
      end
    end
  end
  initial begin
    done = 0;
    void'($value$plusargs("SEED=%d", random_state));
    // Exhaust the legal arithmetic domain independently of traffic reachability.
    // Include amount == Depth: truncating an increment before adding is wrong
    // for non-power-of-two depths and must not replace bounded wrapping.
    for (int ptr = 0; ptr < Depth; ptr++) begin
      for (int amount = 0; amount <= Depth; amount++) begin
        assert (dut.advance(ptr, amount) == (ptr + amount) % Depth)
        else $fatal(1, "bounded wrap mismatch Depth=%0d ptr=%0d amount=%0d", Depth, ptr, amount);
      end
    end
    in_valid = '{default: 0};
    out_ready = '{default: 0};
    in_data = '{default: 0};
    repeat (3) @(negedge clock);
    reset = 0;
    for (int cycle = 0; cycle < 2000; cycle++) begin
      random_state = {
        random_state[30:0], random_state[31] ^ random_state[21] ^ random_state[1] ^ random_state[0]
      };
      flush = cycle % 97 == 96 || cycle == 997;
      reset = cycle % 211 == 210 || cycle == 997;
      for (int s = 0; s < InWidth; s++) begin
        in_valid[s] = s < int'(random_state[7:0]) % (InWidth + 1);
        in_data[s]  = {random_state, ~random_state, 33'(sequence_id + s)};
      end
      for (int s = 0; s < OutWidth; s++)
      out_ready[s] = s < int'(random_state[15:8]) % (OutWidth + 1);
      // Force full occupancy, stalled outputs, then repeated full reclaim.
      // In the Depth-wide case this advances both pointers by exactly Depth.
      if (cycle < 2 * Depth + 16) begin
        in_valid = '{default: 1};
        out_ready = '{default: 1};
        if (cycle < Depth + 2) out_ready = '{default: 0};
      end
      @(posedge clock);
      assert (int'(occupancy) == model.size())
      else $fatal(1, "occupancy mismatch");
      for (int s = 0; s < OutWidth; s++) begin
        assert (out_valid[s] == (!flush && !reset && s < model.size()))
        else $fatal(1, "output validity mismatch");
        if (out_valid[s]) begin
          assert (out_data[s] == model[s])
          else $fatal(1, "visible data mismatch, including stalled output");
        end
      end
      if (int'(occupancy) == Depth) full_seen++;
      pushes = 0;
      pops   = 0;
      for (int s = 0; s < OutWidth; s++)
      if (!flush && !reset && s < model.size() && out_ready[s]) pops++;
      for (int s = 0; s < InWidth; s++) begin
        assert (in_ready[s] ==
                (!flush && !reset && s < Depth - model.size() + (ReclaimSameCycle ? pops : 0)))
        else $fatal(1, "input capacity/full reclaim mismatch");
      end
      pops = 0;
      if (flush || reset) begin
        foreach (in_ready[s])
        assert (!in_ready[s])
        else $fatal(1, "flush accepted input");
        model.delete();
        flush_seen++;
      end else begin
        for (int s = 0; s < OutWidth; s++)
        if (out_valid[s] && out_ready[s]) begin
          assert (model.size() != 0)
          else $fatal(1, "underflow");
          expected = model.pop_front();
          assert (out_data[s] == expected)
          else $fatal(1, "stream lost/duplicated/reordered");
          pops++;
        end
        for (int s = 0; s < InWidth; s++)
        if (in_valid[s] && in_ready[s]) begin
          model.push_back(in_data[s]);
          pushes++;
        end
      end
      sequence_id += pushes;
      if (pushes != 0 && pops != 0) simultaneous++;
      @(negedge clock);
    end
    assert (full_seen > 0 && simultaneous > 0 && flush_seen > 0)
    else $fatal(1, "coverage missing");
    flush = 1;
    in_valid = '{default: 0};
    out_ready = '{default: 0};
    @(negedge clock);
    assert (occupancy == 0)
    else $fatal(1, "flush failed");
    done = 1;
  end
endmodule

module tb_stream_queue #(
    parameter int SweepDepth = 0
);
  logic clock = 0;
  always #5 clock = ~clock;
  logic [10:0] done;
  wire [29:0] bank_done;
  wire sweep_done;
  if (SweepDepth > 0) begin : g_sweep
    wire [SweepDepth-1:0] depth_done;
    for (genvar d = 1; d <= SweepDepth; d++) begin : g_depth
      wire [d*d-1:0] case_done;
      for (genvar i = 1; i <= d; i++) begin : g_input
        for (genvar o = 1; o <= d; o++) begin : g_output
          stream_queue_case #(
              .Depth(d),
              .InWidth(i),
              .OutWidth(o)
          ) dut_case (
              .clock(clock),
              .done(case_done[(i-1)*d+o-1])
          );
        end
      end
      assign depth_done[d-1] = &case_done;
    end
    assign sweep_done = &depth_done;
  end else begin : g_no_sweep
    assign sweep_done = 1'b1;
  end
  // Widths 1..4 and 8: power-of-two, divisible non-power-of-two and
  // incompatible geometries, under both reclaim contracts. Width three /
  // depth eight is the default-w3 RNQ; width eight / depth sixteen is w8.
  for (genvar w = 0; w < 5; w++) begin : g_bank_width
    localparam int Width = w == 4 ? 8 : w + 1;
    for (genvar d = 0; d < 3; d++) begin : g_bank_depth
      localparam int Entries = d == 0 ? 2 * Width : d == 1 ? 8 * Width : 2 * Width + 2;
      for (genvar r = 0; r < 2; r++) begin : g_reclaim
        stream_queue_case #(
            .Depth(Entries),
            .InWidth(Width),
            .OutWidth(Width),
            .ReclaimSameCycle(r == 1)
        ) banked (
            .clock,
            .done(bank_done[6*w+2*d+r])
        );
      end
    end
  end
  stream_queue_case #(
      .Depth(7),
      .InWidth(7),
      .OutWidth(7)
  ) full_width (
      .clock(clock),
      .done(done[5])
  );
  stream_queue_case #(
      .Depth(1),
      .InWidth(1),
      .OutWidth(1)
  ) one (
      clock,
      done[0]
  );
  stream_queue_case #(
      .Depth(7),
      .InWidth(3),
      .OutWidth(4)
  ) expand (
      clock,
      done[1]
  );
  stream_queue_case #(
      .Depth(7),
      .InWidth(4),
      .OutWidth(1)
  ) contract (
      clock,
      done[2]
  );
  stream_queue_case #(
      .Depth(9),
      .InWidth(2),
      .OutWidth(3)
  ) odd (
      clock,
      done[3]
  );
  stream_queue_case #(
      .Depth(8),
      .InWidth(4),
      .OutWidth(4)
  ) wide (
      clock,
      done[4]
  );
  stream_queue_case #(
      .Depth(8),
      .InWidth(4),
      .OutWidth(4),
      .ReclaimSameCycle(1'b0)
  ) wide_registered_capacity (
      clock,
      done[6]
  );
  // FP arithmetic pipelines use non-power-of-two credit queues. Exercise
  // both capacity contracts with the single-reader/single-writer storage.
  for (genvar i = 0; i < 4; i++) begin : g_single_lane
    stream_queue_case #(
        .Depth(i < 2 ? 6 : 12),
        .InWidth(1),
        .OutWidth(1),
        .ReclaimSameCycle((i % 2) == 0)
    ) single_lane (
        .clock,
        .done(done[7+i])
    );
  end
  initial begin
    wait ((&done) && (&bank_done) && sweep_done);
    $display("PASS: randomized stream widths, wrap, full reclaim and flush");
    $finish;
  end
  initial begin
    #30000;
    $fatal(1, "timeout");
  end
endmodule

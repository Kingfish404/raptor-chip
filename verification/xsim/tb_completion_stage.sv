`include "rapt.svh"

module tb_completion_stage;
  localparam int Ports = rapt_pkg::CompletionPorts;
  localparam int PacketBits = $bits(rapt_pkg::completion_t);
  logic clock = 0, reset = 1, flush = 0;
  always #5 clock = ~clock;
  rapt_pkg::completion_t accepted[Ports], completion[Ports], expected[Ports];
  logic [PacketBits-1:0] pattern;
  int received[Ports];
  int flushes = 0;
  int unsigned rng = 32'hc0db2026;

  for (genvar p = 0; p < Ports; p++) begin : g_port
    rapt_completion_stage dut (
        .clock(clock),
        .reset(reset),
        .flush(flush),
        .accepted(accepted[p]),
        .completion(completion[p])
    );
  end

  function automatic int unsigned random_word();
    rng ^= rng << 13;
    rng ^= rng >> 17;
    rng ^= rng << 5;
    return rng;
  endfunction

  initial begin
    for (int p = 0; p < Ports; p++) begin
      accepted[p] = '0;
      expected[p] = '0;
      received[p] = 0;
    end
    repeat (2) @(negedge clock);
    for (int cycle = 0; cycle < 4096; cycle++) begin
      reset = cycle % 257 == 0;
      flush = cycle % 19 < 2;
      if (flush) flushes++;
      for (int p = 0; p < Ports; p++) begin
        // Different full-width packets at every port catch crossed identities,
        // field skew, and cross-instance assertion-history aliasing.
        for (int b = 0; b < PacketBits; b++) begin
          if (b % 32 == 0) void'(random_word());
          pattern[b] = rng[b%32];
        end
        accepted[p] = rapt_pkg::completion_t'(pattern);
        accepted[p].valid = (cycle + p) % 4 != 0;
        expected[p] = accepted[p];
        expected[p].valid = accepted[p].valid && !reset && !flush;
      end
      @(posedge clock);
      #1;
      for (int p = 0; p < Ports; p++) begin
        assert (completion[p].valid == expected[p].valid)
        else $fatal(1, "valid mismatch cycle=%0d port=%0d", cycle, p);
        if (expected[p].valid) begin
          assert (completion[p] == expected[p])
          else $fatal(1, "packet mismatch cycle=%0d port=%0d", cycle, p);
          received[p]++;
        end
      end
      @(negedge clock);
    end
    for (int p = 0; p < Ports; p++)
    assert (received[p] > 2000)
    else $fatal(1, "insufficient port coverage");
    assert (flushes > 400)
    else $fatal(1, "insufficient flush coverage");
    $display("PASS: completion stage RV%0d ports=%0d cycles=4096 flushes=%0d", `RAPT_XLEN, Ports,
             flushes);
    $finish;
  end
endmodule

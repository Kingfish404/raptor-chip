`include "rapt.svh"

// Mixed unsigned arithmetic stresses the shared completion mux and tag reuse.
// Signed arithmetic and exact isolated latencies are covered by div_iterations.
module tb_muldiv_stream;
  localparam int X = `RAPT_XLEN;
  logic clock = 0, reset = 1, flush = 0;
  always #5 clock = ~clock;
  logic [X-1:0] in_a = 0, in_b = 0, out_r;
  logic [4:0] in_op = `RAPT_ALU_MUL___;
  logic in_word = 0, in_valid = 0, in_ready, out_valid;
  logic [3:0] in_tag = 0, out_tag;
  rapt_ieu_mul #(
      .XLEN(X),
      .TAG_W(4)
  ) dut (
      .*
  );

  bit [15:0] pending = 0;
  logic [X-1:0] expected[16];
  bit accepted_last = 0, flushed_last = 0, previous_mul = 0;
  int accepted = 0, retired = 0, killed = 0, mul_count = 0, div_count = 0;
  int back_to_back_mul = 0, simultaneous = 0, stalls = 0, flushes = 0;
  logic [63:0] rng = 64'h6476_3230_2609_0517;
  function automatic logic [63:0] random_bits();
    rng ^= rng << 13;
    rng ^= rng >> 7;
    rng ^= rng << 17;
    return rng;
  endfunction

  function automatic logic [X-1:0] result_for_request();
    logic [X-1:0] a, b, result_bits;
    a = (X > 32 && in_word) ? X'(in_a[31:0]) : in_a;
    b = (X > 32 && in_word) ? X'(in_b[31:0]) : in_b;
    case (in_op)
      `RAPT_ALU_MUL___: result_bits = a * b;
      `RAPT_ALU_DIVU__: result_bits = b == 0 ? '1 : a / b;
      default: result_bits = b == 0 ? a : a % b;
    endcase
    return (X > 32 && in_word) ? X'($signed(result_bits[31:0])) : result_bits;
  endfunction

  // Account at the consuming edge, before the DUT changes registered outputs.
  always @(posedge clock) begin
    accepted_last = 0;
    flushed_last = reset || flush;
    if (reset || flush) begin
      killed += $countones(pending);
      pending = 0;
      previous_mul = 0;
      if (flush) flushes++;
    end else begin
      if (out_valid) begin
        assert (pending[out_tag])
        else $fatal(1, "duplicate/stale completion tag=%0d", out_tag);
        assert (out_r == expected[out_tag])
        else
          $fatal(
              1, "result/tag mismatch tag=%0d got=%h expected=%h", out_tag, out_r, expected[out_tag]
          );
        pending[out_tag] = 0;
        retired++;
      end
      accepted_last = in_valid && in_ready;
      if (accepted_last) begin
        assert (!pending[in_tag])
        else $fatal(1, "driver reused a live tag");
        expected[in_tag] = result_for_request();
        pending[in_tag] = 1;
        accepted++;
        if (out_valid) simultaneous++;
        if (in_op == `RAPT_ALU_MUL___) begin
          mul_count++;
          if (previous_mul) back_to_back_mul++;
        end else div_count++;
      end
      previous_mul = accepted_last && in_op == `RAPT_ALU_MUL___;
      if (in_valid && !in_ready) stalls++;
    end
    assert (accepted == retired + killed + $countones(pending))
    else $fatal(1, "transaction accounting failed");
    #1;
    if (reset || flush)
      assert (!out_valid)
      else $fatal(1, "flush failed to clear valid");
  end

  initial begin
    repeat (3) @(negedge clock);
    reset = 0;
    for (int cycle = 0; cycle < 20000; cycle++) begin
      @(negedge clock);
      flush = cycle > 1200 && ((random_bits() & 127) == 0);
      if (flush) in_valid = 0;
      else if (!in_valid || accepted_last || flushed_last) begin
        // A request stays unchanged under backpressure until accepted/flush.
        in_valid = cycle < 200 || ((random_bits() & 7) != 0);
        in_a = X'(random_bits());
        in_b = X'(random_bits());
        if ((random_bits() & 15) == 0) in_b = 0;
        in_word = X > 32 && ((random_bits() & 1) != 0);
        in_op = cycle < 200 || ((random_bits() & 3) != 0) ? `RAPT_ALU_MUL___ :
            ((random_bits() & 1) != 0 ? `RAPT_ALU_DIVU__ : `RAPT_ALU_REMU__);
        in_tag = 4'(accepted);
      end
    end
    @(negedge clock);
    in_valid = 0;
    flush = 0;
    repeat (X + 8) @(negedge clock);
    assert (pending == 0)
    else $fatal(1, "completion lost at drain");
    assert (accepted > 500 && mul_count > 300 && div_count > 50 && killed > 0
        && back_to_back_mul > 100 && simultaneous > 100 && stalls > 100 && flushes > 20)
    else $fatal(1, "insufficient mixed-stream coverage");
    $display(
        "PASS: mixed mul/div XLEN=%0d accepted=%0d retired=%0d killed=%0d mul=%0d div=%0d consecutive_mul=%0d simultaneous=%0d stalls=%0d flushes=%0d",
        X, accepted, retired, killed, mul_count, div_count, back_to_back_mul, simultaneous, stalls,
        flushes);
    $finish;
  end
  initial begin
    #1000000;
    $fatal(1, "mixed stream timeout");
  end
endmodule

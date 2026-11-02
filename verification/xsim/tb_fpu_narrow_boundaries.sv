`include "rapt.svh"

// Known IEEE results cover the source-subnormal reduction and each end of the
// bounded shift window. Consecutive launches also check the three-cycle slot.
module tb_fpu_narrow_boundaries;
  logic clock = 0, reset = 1, flush = 0, valid = 0;
  logic [63:0] operand = 0, result;
  logic [2:0] rounding_mode = 0;
  logic ready, result_valid;
  logic [4:0] flags;
  logic [31:0] expected_input = 0;
  logic [4:0] expected_input_flags = 0;
  logic [2:0] expected_valid = '0;
  logic [31:0] expected_result[3];
  logic [4:0] expected_flags[3];
  int accepted = 0, completed = 0, killed = 0;
  always #5 clock = ~clock;
  rapt_fpu_convert_narrow dut (.*);

  task automatic sample ();
    @(posedge clock);
    if (reset || flush) begin
      killed += $countones(expected_valid[1:0]);
      expected_valid = '0;
    end else begin
      for (int stage = 2; stage > 0; stage--) begin
        expected_result[stage] = expected_result[stage-1];
        expected_flags[stage] = expected_flags[stage-1];
      end
      expected_result[0] = expected_input;
      expected_flags[0] = expected_input_flags;
      expected_valid = {expected_valid[1:0], valid};
      if (valid) accepted++;
    end
    #1;
    assert (ready == (!reset && !flush))
    else $fatal(1, "converter stalled");
    assert (result_valid == expected_valid[2])
    else $fatal(1, "converter latency changed");
    if (result_valid) begin
      assert (result == {32'hffff_ffff, expected_result[2]} && flags == expected_flags[2])
      else
        $fatal(
            1,
            "narrow result=%h/%h expected=%h/%h",
            result,
            flags,
            expected_result[2],
            expected_flags[2]
        );
      completed++;
    end
  endtask

  task automatic launch(input logic [63:0] value, input int mode, input logic [31:0] answer,
                        input logic [4:0] exceptions);
    @(negedge clock);
    reset = 0;
    flush = 0;
    valid = 1;
    operand = value;
    rounding_mode = 3'(mode);
    expected_input = answer;
    expected_input_flags = exceptions;
    sample ();
  endtask

  initial begin
    logic [63:0] sign_d;
    logic [31:0] sign_s, directed_tiny, half_tiny, above_half, overflow;
    bit magnitude_up;
    repeat (3) begin
      @(negedge clock);
      sample ();
    end
    for (int mode = 0; mode < 5; mode++)
    for (int negative = 0; negative < 2; negative++) begin
      sign_d = 64'(negative) << 63;
      sign_s = 32'(negative) << 31;
      magnitude_up = (mode == 2 && negative != 0) || (mode == 3 && negative == 0);
      directed_tiny = sign_s | 32'(magnitude_up);
      half_tiny = sign_s | 32'(magnitude_up || mode == 4);
      above_half = sign_s | 32'(magnitude_up || mode == 0 || mode == 4);
      overflow = sign_s | ((mode == 0 || mode == 4 || magnitude_up)
          ? 32'h7f80_0000 : 32'h7f7f_ffff);
      launch(sign_d, mode, sign_s, 0);
      launch(sign_d | 64'h0000_0000_0000_0001, mode, directed_tiny, 5'h03);
      launch(sign_d | 64'h000f_ffff_ffff_ffff, mode, directed_tiny, 5'h03);
      launch(sign_d | 64'h0010_0000_0000_0000, mode, directed_tiny, 5'h03);
      launch(sign_d | 64'h3680_0000_0000_0000, mode, directed_tiny, 5'h03);
      launch(sign_d | 64'h368f_ffff_ffff_ffff, mode, directed_tiny, 5'h03);
      launch(sign_d | 64'h3690_0000_0000_0000, mode, half_tiny, 5'h03);
      launch(sign_d | 64'h3690_0000_0000_0001, mode, above_half, 5'h03);
      launch(sign_d | 64'h36a0_0000_0000_0000, mode, sign_s | 32'h0000_0001, 0);
      launch(sign_d | 64'h3810_0000_0000_0000, mode, sign_s | 32'h0080_0000, 0);
      launch(sign_d | 64'h47ef_ffff_e000_0000, mode, sign_s | 32'h7f7f_ffff, 0);
      launch(sign_d | 64'h47f0_0000_0000_0000, mode, overflow, 5'h05);
      launch(sign_d | 64'h7fef_ffff_ffff_ffff, mode, overflow, 5'h05);
      launch(sign_d | 64'h7ff0_0000_0000_0000, mode, sign_s | 32'h7f80_0000, 0);
      launch(sign_d | 64'h7ff0_0000_0000_0001, mode, 32'h7fc0_0000, 5'h10);
      launch(sign_d | 64'h7ff8_1234_5678_9abc, mode, 32'h7fc0_0000, 0);
      launch(sign_d, mode, sign_s, 0);
      launch(sign_d | 64'h3810_0000_0000_0000, mode, sign_s | 32'h0080_0000, 0);
      @(negedge clock);
      valid = 0;
      flush = 1;
      sample ();
    end
    repeat (4) begin
      @(negedge clock);
      flush = 0;
      valid = 0;
      sample ();
    end
    assert (accepted == 180 && accepted == completed + killed && killed == 20)
    else $fatal(1, "converter coverage/ownership gap");
    $display("PASS: narrow boundary rounding/flags/latency accepted=%0d completed=%0d killed=%0d",
             accepted, completed, killed);
    $finish;
  end
endmodule

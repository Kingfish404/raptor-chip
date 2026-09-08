module tb_half_flush;
  logic clock = 0, reset = 1, flush = 0, valid = 0;
  logic [63:0] half_operand, fp_operand;
  logic double_format;
  logic [2:0] rm;
  logic widen_ready, narrow_ready, widen_valid, narrow_valid;
  logic [63:0] widen_result, narrow_result;
  logic [4:0] widen_flags, narrow_flags;
  integer scenarios = 0;
  rapt_fpu_half_to_fp widen (
      .clock,
      .reset,
      .flush,
      .valid,
      .ready(widen_ready),
      .operand(half_operand),
      .target_double(double_format),
      .result(widen_result),
      .flags(widen_flags),
      .result_valid(widen_valid)
  );
  rapt_fpu_fp_to_half narrow (
      .clock,
      .reset,
      .flush,
      .valid,
      .ready(narrow_ready),
      .operand(fp_operand),
      .source_double(double_format),
      .rounding_mode(rm),
      .result(narrow_result),
      .flags(narrow_flags),
      .result_valid(narrow_valid)
  );
  task automatic tick;
    clock = 0;
    #1;
    clock = 1;
    #1;
    clock = 0;
    #1;
  endtask
  task automatic empty;
    if (widen_valid || narrow_valid || !widen_ready || !narrow_ready)
      $fatal(1, "flush/reset did not release converters scenario%0d", scenarios);
  endtask
  initial begin
    half_operand=0;
    fp_operand=0;
    double_format=0;
    rm=0;
    tick();
    reset = 0;
    tick();
    for (int d = 0; d < 2; d++)
    for (int rounding = 0; rounding < 5; rounding++)
    for (int datum = 0; datum < 8; datum++)
    for (int phase = 0; phase < 3; phase++) begin
      double_format=1'(d);
      rm=3'(rounding);
      // Mixture of signaling NaNs, underflow/overflow, malformed box and zeros.
      case (datum)
        0: begin
          half_operand=64'hffffffffffff7c01;
          fp_operand=d?64'h7ff0000000000001:64'hffffffff7f800001;
        end
        1: begin
          half_operand=64'hffffffffffff0001;
          fp_operand=d?64'h3f0ffc0000000000:64'hffffffff387fe000;
        end
        2: begin
          half_operand=64'hffffffffffff8001;
          fp_operand=d?64'hbf0ffc0000000000:64'hffffffffb87fe000;
        end
        3: begin
          half_operand=64'hffffffffffff7bff;
          fp_operand=d?64'h7fefffffffffffff:64'hffffffff7f7fffff;
        end
        4: begin
          half_operand=64'h0000000000007c01;
          fp_operand=64'h000000007f800001;
        end
        5: begin
          half_operand=64'hffffffffffff7e55;
          fp_operand=d?64'h7ff8000000000055:64'hffffffff7fc00055;
        end
        6: begin
          half_operand=64'hffffffffffff8000;
          fp_operand=d?64'h8000000000000000:64'hffffffff80000000;
        end
        default: begin
          half_operand=64'hffffffffffff0000;
          fp_operand=d?64'h0000000000000000:64'hffffffff00000000;
        end
      endcase
      valid = 1;
      // phase0: flush at launch; phase1: flush a presented result;
      // phase2: reset a presented result. No external consumer modeled.
      if (phase == 0) flush = 1;
      tick();
      valid = 0;
      if (phase != 0) begin
        if (!widen_valid || !narrow_valid) $fatal(1, "no presented result");
        if (phase == 1) flush = 1;
        else reset = 1;
        tick();
      end
      empty();
      flush=0;
      reset=0;
      repeat (3) begin
        tick();
        empty();
      end
      // Immediate reuse and a valid numerical control after cancellation.
      half_operand=64'hffffffffffff3c00;
      fp_operand=d?64'h3ff0000000000000:64'hffffffff3f800000;
      valid=1;
      tick();
      valid = 0;
      if(!widen_valid || !narrow_valid || widen_flags!=0 || narrow_flags!=0
          || narrow_result!=64'hffffffffffff3c00
          || widen_result!=(d?64'h3ff0000000000000:64'hffffffff3f800000))
        $fatal(1, "reuse result/flags corrupted scenario%0d", scenarios);
      tick();
      empty();
      scenarios++;
    end
    if (scenarios != 240) $fatal(1, "wrong scenario count");
    $display("PASS half converter flush/reset/reuse scenarios=%0d", scenarios);
    $finish;
  end
endmodule

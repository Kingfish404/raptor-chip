`include "rapt_fp_ops.svh"
// Reset/flush may leave stale payload, but must cancel every valid stage.
// Compare post-cancellation transactions with a clean baseline, not idle data.
module tb_fpu_result_reset;
  logic [17:0] done;
  for (genvar d = 0; d < 2; d++) begin : g_format
    for (genvar k = 0; k < 9; k++) begin : g_kind
      fpu_result_reset_case #(
          .Kind(k),
          .Double(d != 0)
      ) check_case (
          done[d*9+k]
      );
    end
  end
  initial begin
    wait (&done);
    $display("PASS FPU result reset: 18 variants, reset/flush at launch, in flight and output");
    $finish;
  end
  initial begin
    #10000;
    $fatal(1, "timeout");
  end
endmodule
module fpu_result_reset_case #(
    parameter int Kind = 0,
    parameter bit Double = 0
) (
    output logic done = 0
);
  logic clock = 0, reset = 1, flush = 0, valid = 0;
  logic ready, result_valid;
  logic [63:0] result, expected_result;
  logic [4:0] flags, expected_flags;
  wire [63:0] fp = Double ? 64'h3ff8000000000000 : 64'hffffffff3fc00000;
  if (Kind == 0) begin : g_addsub
    rapt_fpu_addsub #(
        .TARGET_DOUBLE(Double)
    ) dut (
        .clock,
        .reset,
        .flush,
        .valid,
        .ready,
        .result,
        .flags,
        .result_valid,
        .operand_a(fp),
        .operand_b(fp),
        .op(Double ? `RAPT_FP_OP_FADD_D : `RAPT_FP_OP_FADD_S),
        .rounding_mode(3'b000)
    );
  end
  if (Kind == 1) begin : g_mul
    rapt_fpu_mul #(
        .TARGET_DOUBLE(Double)
    ) dut (
        .clock,
        .reset,
        .flush,
        .valid,
        .ready,
        .result,
        .flags,
        .result_valid,
        .operand_a(fp),
        .operand_b(fp),
        .rounding_mode(3'b000)
    );
  end
  if (Kind == 2) begin : g_fma
    rapt_fpu_fma #(
        .TARGET_DOUBLE(Double)
    ) dut (
        .clock,
        .reset,
        .flush,
        .valid,
        .ready,
        .result,
        .flags,
        .result_valid,
        .operand_a(fp),
        .operand_b(fp),
        .operand_c(fp),
        .op(Double ? `RAPT_FP_OP_FMADD_D : `RAPT_FP_OP_FMADD_S),
        .rounding_mode(3'b000)
    );
  end
  if (Kind == 3) begin : g_convert_narrow
    rapt_fpu_convert_narrow dut (
        .clock,
        .reset,
        .flush,
        .valid,
        .ready,
        .result,
        .flags,
        .result_valid,
        .operand(64'h3ff8000000000000),
        .rounding_mode(3'b000)
    );
  end
  if (Kind == 4) begin : g_convert_widen
    rapt_fpu_convert_widen dut (
        .clock,
        .reset,
        .flush,
        .valid,
        .ready,
        .result,
        .flags,
        .result_valid,
        .operand(64'hffffffff3fc00000)
    );
  end
  if (Kind == 5) begin : g_int_to_fp
    rapt_fpu_int_to_fp #(
        .TARGET_DOUBLE(Double),
        .INT64_INPUT(Double)
    ) dut (
        .clock,
        .reset,
        .flush,
        .valid,
        .ready,
        .result,
        .flags,
        .result_valid,
        .operand(64'd16777217),
        .rounding_mode(3'b000),
        .unsigned_input(1'b0)
    );
  end
  if (Kind == 6) begin : g_single_to_int_w
    rapt_fpu_single_to_int_w #(
        .SOURCE_DOUBLE(Double)
    ) dut (
        .clock,
        .reset,
        .flush,
        .valid,
        .ready,
        .result,
        .flags,
        .result_valid,
        .operand(fp),
        .rounding_mode(3'b000),
        .unsigned_result(1'b0),
        .int64_target(Double)
    );
  end
  if (Kind == 7) begin : g_fp_to_half
    rapt_fpu_fp_to_half dut (
        .clock,
        .reset,
        .flush,
        .valid,
        .ready,
        .result,
        .flags,
        .result_valid,
        .operand(fp),
        .rounding_mode(3'b000),
        .source_double(Double)
    );
  end
  if (Kind == 8) begin : g_half_to_fp
    rapt_fpu_half_to_fp dut (
        .clock,
        .reset,
        .flush,
        .valid,
        .ready,
        .result,
        .flags,
        .result_valid,
        .operand(64'hffffffffffff3e00),
        .target_double(Double)
    );
  end
  task automatic tick;
    #1;
    clock = 1;
    #1;
    clock = 0;
    #1;
  endtask
  task automatic transaction(input bit capture);
    int count;
    if (!ready) $fatal(1, "not ready kind=%0d", Kind);
    valid = 1;
    tick();
    valid = 0;
    count = 0;
    while (!result_valid && count < 8) begin
      tick();
      count++;
    end
    if (!result_valid || $isunknown({result, flags}))
      $fatal(1, "missing/unknown result kind=%0d", Kind);
    if (capture) begin
      expected_result = result;
      expected_flags = flags;
    end else if ({result, flags} !== {expected_result, expected_flags})
      $fatal(1, "post-reset payload mismatch kind=%0d double=%0d", Kind, Double);
    tick();
  endtask
  initial begin
    tick();
    if (result_valid || !ready) $fatal(1, "cold reset");
    reset = 0;
    transaction(1);
    for (int use_reset = 0; use_reset < 2; use_reset++) begin
      for (int phase = 0; phase < 8; phase++) begin
        valid = 1;
        if (phase != 0) begin
          tick();
          valid = 0;
          repeat (phase - 1) tick();
        end
        reset = use_reset != 0;
        flush = use_reset == 0;
        tick();
        valid = 0;
        if (result_valid || !ready) $fatal(1, "cancel failed kind=%0d phase=%0d", Kind, phase);
        reset = 0;
        flush = 0;
        repeat (8) begin
          tick();
          if (result_valid) $fatal(1, "stale completion kind=%0d", Kind);
        end
        transaction(0);
      end
    end
    done = 1;
  end
endmodule

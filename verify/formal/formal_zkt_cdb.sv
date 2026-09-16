`include "rapt_if.svh"

// Compare the real shared ALU/FP endpoint under identical public occupancy,
// ownership and enable signals but independent arithmetic result values.
module formal_zkt_cdb (
    input clock,
    reset,
    integer_system_pipe_enable,
    fpu_issue_enable,
    input wb_integer_system_accept,
    wb_fpu_accept,
    input rapt_pkg::completion_t integer_public,
    fp_public,
    input [`RAPT_XLEN-1:0] int0,
    int1,
    fp0,
    fp1
);
  rapt_pkg::completion_t i0, i1, f0, f1, out0, out1, control0, control1;
  wire enable0, enable1, fp_ready0, fp_ready1;
  logic past_valid = 0;
  logic integer_occupied, fp_occupied;
  always_ff @(posedge clock) begin
    past_valid <= 1;
    if (!past_valid) assume(reset);
    if (reset) begin
      integer_occupied <= 0;
      fp_occupied <= 0;
    end else begin
      if (!fp_occupied) integer_occupied <= 0;
      fp_occupied <= fp_public.valid && wb_fpu_accept;
      if (integer_public.valid && wb_integer_system_accept) integer_occupied <= 1;
    end
    if (past_valid && !reset) begin
      assume(!(integer_public.valid && wb_integer_system_accept) || !integer_occupied);
      assume(!(fp_public.valid && wb_fpu_accept) || !fp_occupied);
      assert(enable0 == enable1);
      assert(fp_ready0 == fp_ready1);
      assert(out0.valid == out1.valid);
      if (out0.valid) assert(control0 == control1);
      cover(out0.valid && out0.result != out1.result);
      cover(integer_occupied && fp_occupied);
      cover(enable0 && !out0.valid);
    end
  end
  always_comb begin
    i0 = integer_public;
    i0.result = int0;
    i1 = integer_public;
    i1.result = int1;
    f0 = fp_public;
    f0.result = fp0;
    f1 = fp_public;
    f1.result = fp1;
    control0 = out0;
    control0.result = '0;
    control1 = out1;
    control1.result = '0;

  end
  rapt_cdb_arb left_dut (
      .clock,
      .reset,
      .integer_system_pipe_enable,
      .fpu_issue_enable,
      .wb_integer_system_raw(i0),
      .wb_fpu(f0),
      .wb_integer_system_accept,
      .wb_fpu_accept,
      .wb_shared(out0),
      .integer_system_issue_enable(enable0), .fpu_completion_ready(fp_ready0)
  );
  rapt_cdb_arb right_dut (
      .clock,
      .reset,
      .integer_system_pipe_enable,
      .fpu_issue_enable,
      .wb_integer_system_raw(i1),
      .wb_fpu(f1),
      .wb_integer_system_accept,
      .wb_fpu_accept,
      .wb_shared(out1),
      .integer_system_issue_enable(enable1), .fpu_completion_ready(fp_ready1)
  );
endmodule

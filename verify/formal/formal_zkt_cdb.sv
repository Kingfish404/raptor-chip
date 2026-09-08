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
  wire enable0, enable1;
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
    assert (enable0 == enable1);
    assert (control0 == control1);
    assert(out0.valid == ((integer_public.valid && wb_integer_system_accept)
        || (fp_public.valid && wb_fpu_accept)));
    assert (enable0 == (integer_system_pipe_enable && !fp_public.valid && fpu_issue_enable));
    cover (out0.valid && !fp_public.valid && int0 != int1);
    cover (out0.valid && fp_public.valid && wb_fpu_accept && fp0 != fp1);
    // Raw but rejected FP occupancy blocks issue, not an accepted integer WB.
    cover(fp_public.valid && !wb_fpu_accept && integer_public.valid
        && wb_integer_system_accept && out0.valid && !enable0);
    cover (enable0 && !out0.valid);
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
      .integer_system_issue_enable(enable0)
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
      .integer_system_issue_enable(enable1)
  );
endmodule

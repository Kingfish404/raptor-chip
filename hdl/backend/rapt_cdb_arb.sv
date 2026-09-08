`include "rapt.svh"
`include "rapt_if.svh"

module rapt_cdb_arb #(
    parameter type CompletionT = rapt_pkg::completion_t
) (
    input logic clock,
    input logic reset,

    input logic integer_system_pipe_enable,
    input logic fpu_issue_enable,

    input CompletionT wb_integer_system_raw,
    input CompletionT wb_fpu,
    input logic wb_integer_system_accept,
    input logic wb_fpu_accept,
    output CompletionT wb_shared,

    output logic integer_system_issue_enable
);
  // FP has priority because a multi-cycle FMA/divsqrt may complete while the
  // FPQ is blocked. Keep CSR reads of FFLAGS behind the same ownership gate.
  logic fpu_valid, integer_system_valid;
  assign fpu_valid = wb_fpu.valid && wb_fpu_accept;
  assign integer_system_valid = wb_integer_system_raw.valid && wb_integer_system_accept;
  // Scheduling uses the raw FP occupancy indication to keep this combinational
  // arbitration out of the IQ select loop.  Acceptance still controls which
  // result owns the endpoint; a rejected stale FP pulse can cost one issue
  // opportunity, but cannot suppress an already-issued valid ALU/CSR result.
  assign integer_system_issue_enable = integer_system_pipe_enable
      && !wb_fpu.valid && fpu_issue_enable;

  always_comb begin
    wb_shared = fpu_valid ? wb_fpu : wb_integer_system_raw;
    wb_shared.valid = fpu_valid || integer_system_valid;
  end

  // Both producers share the composition-selected integer endpoint. The issue
  // gate must keep valid pulses mutually exclusive; otherwise fixed FP
  // priority would drop an integer/CSR completion.
  `RAPT_SVA(clock, reset, SHARED_ENDPOINT_PRODUCERS_EXCLUSIVE, !(fpu_valid && integer_system_valid))
endmodule

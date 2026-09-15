`include "rapt.svh"

// One accepted producer packet per cycle. Ownership validation/arbitration
// precede this boundary; precise flush is the owner's reclamation boundary.
module rapt_completion_stage #(
    parameter type CompletionT = rapt_pkg::completion_t
) (
    input logic clock,
    input logic reset,
    input logic flush,
    input CompletionT accepted,
    output CompletionT completion
);
  always_ff @(posedge clock) begin
    completion <= accepted;
    if (reset || flush) completion.valid <= 1'b0;
  end

  // Keep $past local to a module port. Some Verilator versions incorrectly
  // merge $past of generate-local aliases across unpacked-array elements.
  `RAPT_SVA_NEXT(clock, reset, COMPLETION_STAGE_FLUSH, flush, !completion.valid)
  `RAPT_SVA_NEXT(clock, reset, COMPLETION_STAGE_PACKET, !flush && accepted.valid,
                 completion == $past(accepted))
  `RAPT_SVA_NEXT(clock, reset, COMPLETION_STAGE_BUBBLE, !accepted.valid, !completion.valid)
endmodule

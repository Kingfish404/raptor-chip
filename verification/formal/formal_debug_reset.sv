`include "rapt.svh"
`include "rapt_soc_if.svh"

// The driver copies the complete inline reset controller verbatim from rapt.sv
// into debug_reset_cone. The production arbiter and its protocol monitor are
// composed below. Core/L2 quiescence before the arbiter, DMI/JTAG transport and
// top-level wiring remain separate obligations; this is not a cluster proof.
module formal_debug_reset #(
    parameter int Capacity = 32,
    parameter int WriteCapacity = 1
) (
    input logic clock,
    input logic reset,
    input logic request,
    axi4_if.slave core_axi,
    axi4_if.slave sb_axi,
    axi4_if.master merged_axi
);
  logic core_block, core_reset, core_bus_idle;
  debug_reset_cone control (
      .clock,
      .reset,
      .dm_ndmreset(request),
      .core_bus_idle,
      .core_block,
      .core_reset
  );
  formal_debug_arbiter #(
      .Capacity(Capacity),
      .WriteCapacity(WriteCapacity)
  ) arbiter (
      .clock,
      .reset,
      .core_block,
      .idle(core_bus_idle),
      .core_axi,
      .sb_axi,
      .merged_axi
  );
  logic past_valid = 0;
  logic waiting;
  always_ff @(posedge clock) begin
    past_valid <= 1;
    if (!past_valid) assume (reset);
    if (reset) waiting <= 0;
    else if (core_reset) waiting <= request;
    else if (request) waiting <= 1;
    if (!reset) begin
      RESET_BLOCK_PENDING : assert (!waiting || core_block);
      RESET_BLOCK_ACTIVE : assert (!core_reset || core_block);
      if (past_valid && !$past(reset)) begin
        if (!$past(core_reset) && core_reset) begin
          RESET_ONLY_AFTER_DRAIN : assert ($past(core_bus_idle));
        end
        if ($past(core_reset && request)) begin
          RESET_HELD_REQUEST : assert (core_reset);
        end
        if ($past(!core_reset && (waiting || request) && core_bus_idle)) begin
          RESET_PENDING_COMPLETES : assert (core_reset);
        end
      end
      RESET_COVER_DRAIN : cover (waiting && !core_bus_idle && !core_reset);
      RESET_COVER_ACTIVE : cover (core_reset);
      RESET_COVER_SHORT_PULSE : cover (waiting && !request && core_reset);
      RESET_COVER_SBA : cover (core_reset && merged_axi.arvalid && merged_axi.arid == 15);
    end
  end
endmodule

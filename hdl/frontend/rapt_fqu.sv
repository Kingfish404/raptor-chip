`include "rapt.svh"
`include "rapt_if.svh"
// Flatten fetch packets into an ordered stream; decode can regroup across
// original fetch boundaries. Prediction and fault metadata stays per instruction.
module rapt_fqu #(
    parameter int unsigned DEPTH = 2,
    parameter int XLEN = `RAPT_XLEN,
    parameter int FetchWidth = rapt_pkg::DecodeWidth,
    parameter int DecodeWidth = rapt_pkg::DecodeWidth
) (
    input logic clock,
    cmu_bcast_if.in cmu_bcast,
    rapt_recovery_if.sink recovery,
    ifu_idu_if.slave ifu_in,
    ifu_idu_if.master idu_out,
    input logic reset
);
  localparam int Entries = DEPTH * (FetchWidth > DecodeWidth ? FetchWidth : DecodeWidth);
  logic [$clog2(Entries+1)-1:0] pmu_count;
  logic pmu_full;
  rapt_stream_queue #(
      .ItemT(rapt_pkg::fetch_slot_t),
      .Depth(Entries),
      .InWidth(FetchWidth),
      .OutWidth(DecodeWidth),
      // Break decode-ready feedback into IFU acceptance during fetch-ahead.
      .ReclaimSameCycle(1'b0)
  ) queue (
      .clock(clock),
      .reset(reset),
      .flush((cmu_bcast.flush_pipe && !recovery.preserve_fetch)
          || recovery.redirect_valid || idu_out.resteer),
      .in_data(ifu_in.slot),
      .in_valid(ifu_in.valid),
      .in_ready(ifu_in.ready),
      .out_data(idu_out.slot),
      .out_valid(idu_out.valid),
      .out_ready(idu_out.ready),
      .occupancy(pmu_count)
  );
  assign pmu_full = pmu_count == Entries;
  assign ifu_in.resteer = idu_out.resteer;
  assign ifu_in.resteer_pc = idu_out.resteer_pc;
  `RAPT_SVA_IMPLY(clock, reset, FQU_RECOVERY_NO_ACCEPT_OR_OUTPUT, recovery.redirect_valid,
                  !ifu_in.ready[0] && !idu_out.valid[0])
endmodule

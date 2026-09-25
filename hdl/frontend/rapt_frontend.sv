`include "rapt.svh"
`include "rapt_if.svh"
`include "rapt_soc.svh"
`include "rapt_soc_if.svh"
`include "rapt_dpi_c.svh"

// Fetch/predict/decode composition. Rename belongs to the backend so its
// checkpoint, retirement and physical-register feedback stay within that block.
module rapt_frontend #(
    parameter int XLEN = `RAPT_XLEN
) (
    input logic clock,
    input logic reset,
    cmu_bcast_if.in cmu_bcast,
    csr_bcast_if.in csr_bcast,
    rapt_recovery_if.sink recovery,
    ifu_l1i_if.master ifu_l1i,
    idu_rnu_if.master idu_rnu,
    output logic empty_o,
    output logic [63:0] snapshot_ghr,
    output logic [7:0] snapshot_phr,
    input logic history_restore = 1'b0,
    input logic [63:0] restore_ghr = '0,
    input logic [7:0] restore_phr = '0
);
  ifu_idu_if ifu_fqu ();
  ifu_idu_if fqu_idu ();
  ifu_bpu_if ifu_bpu ();
  idu_bpu_if idu_bpu ();
  rapt_bpu bpu (
      .clock(clock),

      .cmu_bcast(cmu_bcast),

      .ifu_bpu(ifu_bpu),
      .idu_bpu(idu_bpu),
      .execute_recover(history_restore),
      .execute_ghr(restore_ghr),
      .execute_phr(restore_phr),
      .snapshot_ghr(snapshot_ghr),
      .snapshot_phr(snapshot_phr),

      .reset(reset)
  );

  // IFU (Instruction Fetch Unit)
  logic ifu_response_pending;
  rapt_ifu ifu (
      .clock(clock),

      .cmu_bcast(cmu_bcast),
      .recovery(recovery),

      .ifu_bpu(ifu_bpu),
      .ifu_l1i(ifu_l1i),
      .ifu_idu(ifu_fqu),
      .ifu_hazard(),
      .response_pending_o(ifu_response_pending),

      .reset(reset)
  );

  rapt_fqu fqu (
      .clock(clock),

      .cmu_bcast(cmu_bcast),
      .recovery(recovery),

      .ifu_in (ifu_fqu),
      .idu_out(fqu_idu),

      .reset(reset)
  );

  // IDU (Instruction Decode Unit)
  rapt_idu idu (
      .clock(clock),

      .cmu_bcast(cmu_bcast),
      .recovery(recovery),
      .csr_bcast(csr_bcast),

      .ifu_idu(fqu_idu),
      .idu_bpu(idu_bpu),
      .idu_rnu(idu_rnu),

      .reset(reset)
  );

  // Same emptiness predicate previously used by the core IO guard. This is
  // a combinational status, not a delayed authorization or flush indication.
  assign empty_o = !ifu_response_pending && !ifu_fqu.valid[0]
      && !fqu_idu.valid[0] && !idu_rnu.valid[0];
endmodule

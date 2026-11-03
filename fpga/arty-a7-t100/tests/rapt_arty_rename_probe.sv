`include "rapt_if.svh"
module rapt_arty_rename_probe (
    input logic clock,
    input logic reset,
    input logic valid_i,
    input logic [4:0] rd_i,
    input logic [4:0] rs1_i,
    output logic ready_o,
    output logic valid_o,
    output logic [5:0] pr1_o,
    output logic [5:0] prd_o,
    output logic [5:0] map_o
);
  idu_rnu_if decoded ();
  rnu_rou_if renamed ();
  rou_cmu_if commit_bus ();
  cmu_bcast_if broadcast ();
  rapt_recovery_if recovery ();
  checkpoint_release_if release_bus ();
  logic [5:0] map_snapshot[32], rat_snapshot[32];
  assign ready_o = decoded.ready[0];
  assign valid_o = renamed.valid[0];
  assign pr1_o   = renamed.slot[0].pr1;
  assign prd_o   = renamed.slot[0].prd;
  assign map_o   = map_snapshot[2];
  always_comb begin
    decoded.slot[0] = '0;
    decoded.slot[0].uop.rd = rd_i;
    decoded.slot[0].rs1 = rs1_i;
  end
  assign decoded.valid[0] = valid_i;
  assign renamed.ready[0] = 1'b1;
  assign commit_bus.slot[0] = '0;
  assign broadcast.flush_pipe = 1'b0;
  assign recovery.pending = 1'b0;
  assign recovery.redirect_valid = 1'b0;
  assign recovery.checkpoint_valid = 1'b0;
  assign recovery.checkpoint = '0;
  assign recovery.taken = 1'b0;
  for (genvar p = 0; p < rapt_pkg::CompletionPorts; p++) begin : g_release
    assign release_bus.valid[p] = 1'b0;
    assign release_bus.checkpoint[p] = '0;
  end
  rapt_rnu u_rnu (
      .clock(clock),
      .reset(reset),
      .rou_cmu(commit_bus),
      .cmu_bcast(broadcast),
      .idu_rnu(decoded),
      .rnu_rou(renamed),
      .recovery(recovery),
      .checkpoint_release(release_bus),
      .snapshot_ghr('0),
      .snapshot_phr('0),
      .history_restore(),
      .restore_ghr(),
      .restore_phr(),
      .map_snapshot(map_snapshot),
      .rat_snapshot(rat_snapshot)
  );
endmodule

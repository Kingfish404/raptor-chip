`include "rapt_sva.svh"

// Single-entry core-side control bridge. The core resolves scalar dependencies
// before cmd acceptance. head_safe means the matching ROB head may execute
// irrevocably (including required older-memory ordering). After authorization
// the core must retain that owner until completion; kill cannot undo effects.
// Metadata carries immutable PC/physical destination/etc., in a core-owned
// layout. Result payload carries ALL VPU result/CSR/trap fields unchanged.
// Both endpoints reset/drain together. Finite identity reuse requires external
// work to have drained. This module does not implement LSU ordering or mapping
// result fields into the scalar completion type.
module rapt_vpu_core_adapter #(
    parameter int RobBits=6,
    GenerationBits=4,
    parameter int CommandBits=160,
    ResultBits=128,
    MetadataBits=64,
    parameter int TagBits=RobBits+GenerationBits
) (
    input logic clock,
    reset,
    input logic cmd_valid,
    output logic cmd_ready,
    input logic [RobBits-1:0] cmd_slot,
    input logic [GenerationBits-1:0] cmd_generation,
    input logic [CommandBits-1:0] cmd_payload,
    input logic [MetadataBits-1:0] cmd_metadata,
    input logic head_valid,
    head_safe,
    input logic [RobBits-1:0] head_slot,
    input logic [GenerationBits-1:0] head_generation,
    input logic kill_valid,
    input logic [RobBits-1:0] kill_slot,
    input logic [GenerationBits-1:0] kill_generation,
    output logic busy,
    authorized,
    cancelled,
    kill_blocked,
    output logic rsp_valid,
    input logic rsp_ready,
    output logic [RobBits-1:0] rsp_slot,
    output logic [GenerationBits-1:0] rsp_generation,
    output logic [MetadataBits-1:0] rsp_metadata,
    output logic [ResultBits-1:0] rsp_payload,
    output logic response_dropped,
    output logic vpu_cmd_valid,
    input logic vpu_cmd_ready,
    output logic [TagBits-1:0] vpu_cmd_tag,
    output logic [CommandBits-1:0] vpu_cmd_payload,
    output logic vpu_authorize_valid,
    input logic vpu_authorize_ready,
    output logic [TagBits-1:0] vpu_authorize_tag,
    output logic vpu_kill_valid,
    output logic [TagBits-1:0] vpu_kill_tag,
    input logic vpu_rsp_valid,
    output logic vpu_rsp_ready,
    input logic [TagBits-1:0] vpu_rsp_tag,
    input logic [ResultBits-1:0] vpu_rsp_payload
);
  logic live_q, authorized_q, cmd_fire, kill_match, grant_fire, response_match;
  logic [TagBits-1:0] tag_q;
  logic [MetadataBits-1:0] metadata_q;
  if (RobBits<1 || GenerationBits<1 || TagBits!=RobBits+GenerationBits
      || CommandBits<1 || ResultBits<1 || MetadataBits<1) begin : g_bad_config
    initial $fatal(1, "Invalid VPU core adapter widths");
  end
  assign busy = live_q;
  assign authorized = live_q && authorized_q;
  assign vpu_cmd_valid = !reset && !live_q && cmd_valid;
  assign cmd_ready = !reset && !live_q && vpu_cmd_ready;
  assign cmd_fire = cmd_valid && cmd_ready;
  assign vpu_cmd_tag = {cmd_generation,cmd_slot};
  assign vpu_cmd_payload = cmd_payload;
  assign vpu_kill_valid = !reset && kill_valid;
  assign vpu_kill_tag = {kill_generation,kill_slot};
  assign kill_match = kill_valid && vpu_kill_tag == tag_q;
  assign cancelled = !reset && ((live_q && !authorized_q && kill_match)
      || (cmd_fire && kill_valid && vpu_kill_tag == vpu_cmd_tag));
  assign kill_blocked = !reset && authorized && kill_match;
  // Authorization is a conditional grant, re-evaluated until accepted. A
  // simultaneous matching kill wins over it, just as in rapt_vpu_owner.
  assign vpu_authorize_valid = !reset && live_q && !authorized_q && !kill_match
      && head_valid && head_safe && {head_generation,head_slot} == tag_q;
  assign vpu_authorize_tag = tag_q;
  assign grant_fire = vpu_authorize_valid && vpu_authorize_ready;
  assign response_match = live_q && authorized_q && vpu_rsp_tag == tag_q;
  assign rsp_valid = !reset && vpu_rsp_valid && response_match;
  assign vpu_rsp_ready = !reset && (!response_match || rsp_ready);
  assign response_dropped = vpu_rsp_valid && vpu_rsp_ready && !response_match;
  assign {rsp_generation,rsp_slot} = tag_q;
  assign rsp_metadata = metadata_q;
  assign rsp_payload = vpu_rsp_payload;
  always_ff @(posedge clock) begin
    if (reset) begin
      live_q <= 0;
      authorized_q <= 0;
      tag_q <= '0;
      metadata_q <= '0;
    end else begin
      if (cmd_fire && !cancelled) begin
        live_q <= 1;
        authorized_q <= 0;
        tag_q <= vpu_cmd_tag;
        metadata_q <= cmd_metadata;
      end
      if (grant_fire) authorized_q <= 1;
      if (cancelled || (rsp_valid && rsp_ready)) begin
        live_q <= 0;
        authorized_q <= 0;
      end
    end
  end
  `RAPT_SVA_IMPLY(clock, reset, VPU_ADAPTER_NO_EARLY_RESULT, rsp_valid, authorized)
  `RAPT_SVA_NEXT(clock, reset, VPU_ADAPTER_METADATA_HOLD, rsp_valid && !rsp_ready,
                 rsp_valid && $stable({rsp_slot, rsp_generation, rsp_metadata, rsp_payload}))
endmodule

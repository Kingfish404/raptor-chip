// Public-interface transaction ledger; arbitrary inputs, no traffic assumptions.
module formal_core_adapter #(
    parameter int RobBits=6,
    GenerationBits=4,
    parameter int CommandBits=160,
    ResultBits=128,
    MetadataBits=64,
    parameter int TagBits=RobBits+GenerationBits
) (
    output logic correct,
    output logic [10:0] witnessed,
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
  rapt_vpu_core_adapter #(
      .RobBits(RobBits),
      .GenerationBits(GenerationBits),
      .CommandBits(CommandBits),
      .ResultBits(ResultBits),
      .MetadataBits(MetadataBits),
      .TagBits(TagBits)
  ) dut (
      .*
  );
  logic seen_reset = 0, outstanding, irrevocable, retired;
  logic [TagBits-1:0] ticket, retired_ticket;
  logic [MetadataBits-1:0] saved_metadata;
  logic accept, revoke, grant, receive, finish, eligible, head_matches, kill_matches;
  logic [9:0] events;
  assign accept=!reset&&!outstanding&&cmd_valid&&vpu_cmd_ready;
  assign kill_matches=kill_valid&&{kill_generation,kill_slot}==ticket;
  assign head_matches=head_valid&&{head_generation,head_slot}==ticket;
  assign revoke=!reset&&((outstanding&&!irrevocable&&kill_matches)
      ||(accept&&kill_valid&&{kill_generation,kill_slot}=={cmd_generation,cmd_slot}));
  assign eligible=!reset&&outstanding&&!irrevocable&&head_matches&&head_safe&&!kill_matches;
  assign grant=eligible&&vpu_authorize_ready;
  assign receive=!reset&&outstanding&&irrevocable&&vpu_rsp_valid&&vpu_rsp_tag==ticket;
  assign finish=receive&&rsp_ready;
  always_ff @(posedge clock) begin
    if (reset) begin
      seen_reset<=1;
      outstanding<=0;
      irrevocable<=0;
      ticket<=0;
      saved_metadata<=0;
      retired<=0;
      retired_ticket<=0;
      witnessed[9:0]<=0;
    end else begin
      if (accept && !revoke) begin
        outstanding<=1;
        irrevocable<=0;
        ticket<={cmd_generation,cmd_slot};
        saved_metadata<=cmd_metadata;
      end
      if (grant) irrevocable <= 1;
      if (revoke || finish) begin
        outstanding<=0;
        irrevocable<=0;
      end
      if (finish) begin
        retired<=1;
        retired_ticket<=ticket;
      end
      witnessed[9:0] <= witnessed[9:0] | events;
    end
  end
  always_comb begin
    correct = 1;
    if (seen_reset && !reset) begin
      correct &= busy == outstanding && authorized == (outstanding && irrevocable);
      correct &= cmd_ready == (!outstanding && vpu_cmd_ready);
      correct &= vpu_cmd_valid == (!outstanding && cmd_valid);
      if (vpu_cmd_valid)
        correct &= vpu_cmd_tag == {cmd_generation, cmd_slot} && vpu_cmd_payload == cmd_payload;
      correct &= vpu_authorize_valid == eligible;
      if (vpu_authorize_valid) correct &= vpu_authorize_tag == ticket;
      correct &= vpu_kill_valid == kill_valid && vpu_kill_tag == {kill_generation, kill_slot};
      correct &= cancelled==revoke&&kill_blocked==(outstanding&&irrevocable&&kill_matches);
      correct &= rsp_valid == receive;
      correct &= vpu_rsp_ready==(!(outstanding&&irrevocable&&vpu_rsp_tag==ticket)||rsp_ready);
      correct &= response_dropped == (vpu_rsp_valid && !receive);
      if (rsp_valid)
        correct &= {rsp_generation,rsp_slot}==ticket
          &&rsp_metadata==saved_metadata&&rsp_payload==vpu_rsp_payload;
    end
    if (reset)
      correct &= !cmd_ready&&!vpu_cmd_valid&&!vpu_authorize_valid
        &&!vpu_kill_valid&&!cancelled&&!kill_blocked&&!rsp_valid&&!vpu_rsp_ready&&!response_dropped;
    events='0;
    events[0]=finish;
    events[1]=accept&&revoke;
    events[2]=outstanding&&!irrevocable&&head_matches&&head_safe&&revoke;
    events[3]=outstanding&&irrevocable&&kill_matches;
    events[4]=receive&&!rsp_ready;
    events[5]=outstanding&&!irrevocable&&vpu_rsp_valid&&vpu_rsp_tag==ticket;
    events[6]=outstanding&&irrevocable&&vpu_rsp_valid&&vpu_rsp_tag!=ticket;
    events[7]=outstanding&&!irrevocable&&head_matches&&!head_safe;
    events[8]=outstanding&&!irrevocable&&head_valid&&head_slot==ticket[RobBits-1:0]
        &&head_generation!=ticket[TagBits-1:RobBits];
    events[9]=accept&&!revoke&&retired&&{cmd_generation,cmd_slot}==retired_ticket;
    witnessed[10]=seen_reset&&reset&&outstanding;
  end
endmodule

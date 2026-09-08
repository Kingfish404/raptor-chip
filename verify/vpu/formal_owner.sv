// Public-interface transaction ledger. Inputs are unconstrained, including
// malformed/early/duplicate responses and arbitrary backpressure. Only a
// synchronous reset at the first sampled edge is required by the runner.
module formal_owner #(
    parameter int TagBits=3,
    CommandBits=17,
    ResultBits=29
) (
    input logic clock,
    reset,
    input logic cmd_valid,
    input logic [TagBits-1:0] cmd_tag,
    input logic [CommandBits-1:0] cmd_payload,
    input logic authorize_valid,
    input logic [TagBits-1:0] authorize_tag,
    input logic kill_valid,
    input logic [TagBits-1:0] kill_tag,
    input logic engine_ready,
    result_valid,
    input logic [TagBits-1:0] result_tag,
    input logic [ResultBits-1:0] result_payload,
    input logic rsp_ready,
    output logic correct,
    output logic [10:0] witnessed
);
  logic cmd_ready, authorize_ready, cancelled, kill_blocked, busy;
  logic engine_valid, result_ready, result_dropped, rsp_valid;
  logic [TagBits-1:0] engine_tag, rsp_tag;
  logic [CommandBits-1:0] engine_payload;
  logic [ResultBits-1:0] rsp_payload;
  rapt_vpu_owner #(
      .TagBits(TagBits),
      .CommandBits(CommandBits),
      .ResultBits(ResultBits)
  ) dut (
      .*
  );

  logic seen_reset = 0;
  logic live, authorized, issued, completed;
  logic [TagBits-1:0] ticket, retired_ticket;
  logic [CommandBits-1:0] request_data;
  logic [ResultBits-1:0] response_data;
  logic retired;
  logic accept, revoke, grant, issue, receive, retire;
  logic expected_ready, expected_authorize, expected_issue, expected_response;
  logic [9:0] events;
  assign expected_ready = !reset && !live;
  assign accept = cmd_valid && expected_ready;
  assign revoke = !reset && kill_valid && ((live && !authorized && kill_tag == ticket)
      || (accept && kill_tag == cmd_tag));
  assign expected_authorize = !reset && live && !authorized && authorize_tag == ticket
      && !(kill_valid && kill_tag == ticket);
  assign grant = authorize_valid && expected_authorize;
  assign expected_issue = !reset && live && authorized && !issued && !completed;
  assign issue = expected_issue && engine_ready;
  assign receive = !reset && result_valid && live && authorized && !completed
      && (issued || issue) && result_tag == ticket;
  assign expected_response = !reset && live && completed;
  assign retire = expected_response && rsp_ready;
  always_ff @(posedge clock) begin
    if (reset) begin
      seen_reset <= 1;
      live <= 0;
      authorized <= 0;
      issued <= 0;
      completed <= 0;
      ticket <= 0;
      request_data <= 0;
      response_data <= 0;
      retired <= 0;
      retired_ticket <= 0;
      witnessed[9:0] <= 0;
    end else begin
      if (accept && !revoke) begin
        live <= 1;
        authorized <= 0;
        issued <= 0;
        completed <= 0;
        ticket <= cmd_tag;
        request_data <= cmd_payload;
      end
      if (revoke || retire) begin
        live <= 0;
        authorized <= 0;
        issued <= 0;
        completed <= 0;
      end
      if (grant) authorized <= 1;
      if (issue) issued <= 1;
      if (receive) begin
        completed <= 1;
        response_data <= result_payload;
      end
      if (retire) begin
        retired <= 1;
        retired_ticket <= ticket;
      end
      witnessed[9:0] <= witnessed[9:0] | events;
    end
  end
  always_comb begin
    correct = 1;
    if (seen_reset && !reset) begin
      correct &= cmd_ready == expected_ready && busy == live;
      correct &= authorize_ready == expected_authorize;
      correct &= cancelled == revoke;
      correct &= kill_blocked == (live && authorized && kill_valid && kill_tag == ticket);
      correct &= engine_valid == expected_issue && rsp_valid == expected_response;
      correct &= result_ready && result_dropped == (result_valid && !receive);
      if (engine_valid) correct &= engine_tag == ticket && engine_payload == request_data;
      if (rsp_valid) correct &= rsp_tag == ticket && rsp_payload == response_data;
    end
    if (reset)
      correct &= !cmd_ready && !authorize_ready && !engine_valid && !rsp_valid
        && !result_ready && !cancelled && !kill_blocked;
    events = 0;
    events[0] = retire;
    events[1] = accept && revoke;
    events[2] = live && !authorized && revoke && authorize_valid && authorize_tag == ticket;
    events[3] = live && authorized && kill_valid && kill_tag == ticket;
    events[4] = expected_response && !rsp_ready;
    events[5] = receive && !issued;
    events[6] = live && issued && !completed && result_valid && result_tag != ticket;
    events[7] = expected_response && result_valid && result_tag == ticket;
    events[8] = accept && !revoke && retired && cmd_tag == retired_ticket;
    events[9] = expected_issue && !engine_ready;
    witnessed[10] = seen_reset && reset && live;
  end
endmodule

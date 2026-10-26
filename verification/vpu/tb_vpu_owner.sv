module tb_vpu_owner #(
    parameter int TagBits = 4
);
  logic clock = 0, reset = 1;
  logic cmd_valid = 0, cmd_ready;
  logic [TagBits-1:0] cmd_tag = 0;
  logic [31:0] cmd_payload = 0;
  logic authorize_valid = 0, authorize_ready;
  logic [TagBits-1:0] authorize_tag = 0;
  logic kill_valid = 0;
  logic [TagBits-1:0] kill_tag = 0;
  logic cancelled, kill_blocked, busy, engine_valid, engine_ready = 0;
  logic [TagBits-1:0] engine_tag;
  logic [31:0] engine_payload;
  logic result_valid = 0, result_ready;
  logic [TagBits-1:0] result_tag = 0;
  logic [31:0] result_payload = 0;
  logic result_dropped, rsp_valid, rsp_ready = 0;
  logic [TagBits-1:0] rsp_tag;
  logic [31:0] rsp_payload;
  int completions = 0, cancellations = 0, drops = 0;
  rapt_vpu_owner #(
      .TagBits(TagBits),
      .CommandBits(32),
      .ResultBits(32)
  ) dut (
      .*
  );

  task automatic tick;
    #1;
    if (result_dropped) drops++;
    clock = 1;
    #1;
    clock = 0;
  endtask
  task automatic inject(input logic [TagBits-1:0] tag, input logic [31:0] payload,
                        input logic drop);
    result_valid = 1;
    result_tag = tag;
    result_payload = payload;
    #1;
    if (!result_ready || result_dropped != drop) $fatal(1, "result disposition tag=%h", tag);
    tick();
    result_valid = 0;
  endtask

  initial begin
    tick();
    reset = 0;
    for (int i = 0; i < 1024; i++) begin
      cmd_tag = TagBits'(i);
      cmd_payload = 32'hcafebabe ^ 32'(i);
      cmd_valid = 1;
      #1;
      if (!cmd_ready) $fatal(1, "idle request rejected");
      // Cancellation can coincide with initial command acceptance too.
      if (i % 7 == 0) begin
        kill_valid = 1;
        kill_tag = cmd_tag;
      end
      #1;
      if (cancelled != kill_valid) $fatal(1, "same-cycle cancellation");
      tick();
      cmd_valid = 0;
      kill_valid = 0;
      if (i % 7 == 0) begin
        if (busy || engine_valid || rsp_valid) $fatal(1, "cancelled acceptance leaked");
        cancellations++;
        continue;
      end
      if (!busy || engine_valid) $fatal(1, "missing pending owner");
      // A matching result before authorization/issue is not a real result.
      inject(cmd_tag, '1, 1);
      if (!busy || rsp_valid || engine_valid) $fatal(1, "pre-issue result accepted");
      authorize_valid = 1;
      authorize_tag = cmd_tag ^ TagBits'(1);
      #1;
      if (authorize_ready) $fatal(1, "wrong identity grant");
      tick();
      authorize_tag = cmd_tag;
      if (i % 5 == 0) begin
        kill_valid = 1;
        kill_tag = cmd_tag;
        #1;
        if (!cancelled || authorize_ready) $fatal(1, "kill/grant priority");
        tick();
        kill_valid = 0;
        authorize_valid = 0;
        if (busy || engine_valid || rsp_valid) $fatal(1, "pending kill leaked");
        cancellations++;
        continue;
      end
      #1;
      if (!authorize_ready) $fatal(1, "matching grant rejected");
      tick();
      authorize_valid = 0;
      for (int stall = 0; stall < 4; stall++) begin
        if (!engine_valid || engine_tag != cmd_tag || engine_payload != cmd_payload)
          $fatal(1, "issue stalled payload");
        tick();
      end
      inject(cmd_tag, '1, 1);  // Not yet accepted by the engine.
      kill_valid = 1;
      kill_tag = cmd_tag;
      #1;
      if (!kill_blocked || cancelled) $fatal(1, "authorized command killed");
      tick();
      kill_valid = 0;
      engine_ready = 1;
      if (i % 2 == 0) begin
        inject(cmd_tag, cmd_payload ^ 32'h12345678, 0);  // zero-cycle engine
      end else begin
        tick();
        engine_ready = 0;
        inject(cmd_tag ^ TagBits'(1), 32'hffffffff, 1);
        if (rsp_valid || !busy) $fatal(1, "stale RUN result poisoned owner");
        inject(cmd_tag, cmd_payload ^ 32'h12345678, 0);
      end
      engine_ready = 0;
      for (int stall = 0; stall < 4; stall++) begin
        if (!rsp_valid || rsp_tag != cmd_tag || rsp_payload != (cmd_payload ^ 32'h12345678))
          $fatal(1, "completion payload changed");
        // Duplicate/stale engine results cannot overwrite a held response.
        inject(cmd_tag, 32'(stall), 1);
      end
      rsp_ready = 1;
      tick();
      rsp_ready = 0;
      if (busy || rsp_valid) $fatal(1, "retired owner retained");
      inject(cmd_tag, '1, 1);  // late duplicate after release
      completions++;
    end
    if (completions < 600 || cancellations < 250 || drops < 4000) $fatal(1, "coverage missing");
    $display("PASS owner TagBits=%0d completions=%0d cancellations=%0d drops=%0d", TagBits,
             completions, cancellations, drops);
    $finish;
  end
endmodule

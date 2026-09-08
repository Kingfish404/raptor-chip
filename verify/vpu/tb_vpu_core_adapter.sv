module tb_vpu_core_adapter #(
    parameter int RobBits=3,
    GenerationBits=2
);
  localparam int TagBits = RobBits + GenerationBits;
  logic clock = 0, reset = 1, cmd_valid = 0, cmd_ready;
  logic [RobBits-1:0] cmd_slot = 0, head_slot = 0, kill_slot = 0, rsp_slot;
  logic [GenerationBits-1:0]
      cmd_generation = 0, head_generation = 0, kill_generation = 0, rsp_generation;
  logic [31:0] cmd_payload = 0, rsp_payload, vpu_cmd_payload, vpu_rsp_payload;
  logic [63:0] cmd_metadata = 0, rsp_metadata;
  logic head_valid = 0, head_safe = 0, kill_valid = 0, busy, authorized, cancelled, kill_blocked;
  logic rsp_valid, rsp_ready = 0, response_dropped;
  logic vpu_cmd_valid, vpu_cmd_ready, vpu_authorize_valid, vpu_authorize_ready, vpu_kill_valid;
  logic [TagBits-1:0] vpu_cmd_tag, vpu_authorize_tag, vpu_kill_tag, vpu_rsp_tag;
  logic vpu_rsp_valid, vpu_rsp_ready;
  logic engine_valid, engine_ready = 0;
  logic [TagBits-1:0] engine_tag, result_tag = 0, owner_rsp_tag;
  logic [31:0] engine_payload, result_payload = 0, owner_rsp_payload;
  logic result_valid = 0, result_ready, owner_cancelled, owner_blocked, owner_busy, owner_dropped;
  logic owner_rsp_valid, inject = 0;
  logic [TagBits-1:0] inject_tag = 0;
  int completed = 0, killed = 0, dropped = 0;
  rapt_vpu_core_adapter #(
      .RobBits(RobBits),
      .GenerationBits(GenerationBits),
      .CommandBits(32),
      .ResultBits(32),
      .MetadataBits(64)
  ) dut (
      .*
  );
  rapt_vpu_owner #(
      .TagBits(TagBits),
      .CommandBits(32),
      .ResultBits(32)
  ) owner (
      .clock,
      .reset,
      .cmd_valid(vpu_cmd_valid),
      .cmd_ready(vpu_cmd_ready),
      .cmd_tag(vpu_cmd_tag),
      .cmd_payload(vpu_cmd_payload),
      .authorize_valid(vpu_authorize_valid),
      .authorize_ready(vpu_authorize_ready),
      .authorize_tag(vpu_authorize_tag),
      .kill_valid(vpu_kill_valid),
      .kill_tag(vpu_kill_tag),
      .cancelled(owner_cancelled),
      .kill_blocked(owner_blocked),
      .busy(owner_busy),
      .engine_valid,
      .engine_ready,
      .engine_tag,
      .engine_payload,
      .result_valid,
      .result_ready,
      .result_tag,
      .result_payload,
      .result_dropped(owner_dropped),
      .rsp_valid(owner_rsp_valid),
      .rsp_ready(vpu_rsp_ready&&!inject),
      .rsp_tag(owner_rsp_tag),
      .rsp_payload(owner_rsp_payload)
  );
  assign vpu_rsp_valid=inject||owner_rsp_valid;
  assign vpu_rsp_tag=inject?inject_tag:owner_rsp_tag;
  assign vpu_rsp_payload=inject?32'hdeadbeef:owner_rsp_payload;
  task automatic tick;
    #1;
    if (cancelled != owner_cancelled || kill_blocked != owner_blocked || busy != owner_busy)
      $fatal(1, "adapter/owner lifecycle disagreement");
    if (result_valid && (!result_ready || owner_dropped))
      $fatal(1, "numeric completion was not accepted exactly once");
    if (response_dropped) dropped++;
    clock = 1;
    #1;
    clock = 0;
    #1;
  endtask
  initial begin
    tick();
    reset = 0;
    for (int i = 0; i < 256; i++) begin
      cmd_slot=RobBits'(i);
      cmd_generation=GenerationBits'(i>>RobBits);
      cmd_payload=32'h12340000^32'(i);
      cmd_metadata=64'hfeed000000000000|64'(i);
      cmd_valid=1;
      head_valid=0;
      head_safe=0;
      kill_slot=cmd_slot;
      kill_generation=cmd_generation;
      kill_valid=(i%7==0);
      #1;
      if (!cmd_ready) $fatal(1, "command admission");
      tick();
      cmd_valid=0;
      kill_valid=0;
      if (i % 7 == 0) begin
        if (busy) $fatal(1, "same-cycle cancellation");
        killed++;
        continue;
      end
      // Matching but premature completion must not release the metadata.
      inject_tag={cmd_generation,cmd_slot};
      inject=1;
      #1;
      if (!response_dropped || rsp_valid) $fatal(1, "early response admission");
      tick();
      inject=0;
      cmd_metadata='1;
      cmd_payload='1;
      head_valid=1;
      head_safe=1;
      head_slot=cmd_slot;
      head_generation=cmd_generation^GenerationBits'(1);
      #1;
      if (vpu_authorize_valid) $fatal(1, "wrong generation authorization");
      tick();
      head_generation=cmd_generation;
      head_safe=0;
      #1;
      if (vpu_authorize_valid) $fatal(1, "unsafe head authorization");
      tick();
      head_safe = 1;
      if (i % 5 == 0) begin
        kill_valid = 1;
        #1;
        if (!cancelled || vpu_authorize_valid) $fatal(1, "kill must beat authorization");
        tick();
        kill_valid = 0;
        killed++;
        continue;
      end
      tick();
      head_valid=0;
      head_safe=0;
      if (!authorized || !engine_valid) $fatal(1, "missing authorized execution");
      inject_tag={cmd_generation,cmd_slot}^TagBits'(1);
      inject=1;
      #1;
      if (!response_dropped || rsp_valid) $fatal(1, "wrong live response identity");
      tick();
      inject=0;
      kill_valid=1;
      #1;
      if (!kill_blocked || cancelled) $fatal(1, "irrevocable owner cancelled");
      repeat (i % 4 + 1) tick();
      kill_valid = 0;
      if (engine_payload != (32'h12340000 ^ 32'(i))) $fatal(1, "command capture");
      result_tag=engine_tag;
      result_payload=engine_payload^32'h55aa55aa;
      engine_ready=1;
      // Alternate immediate and delayed numeric completions through owner.
      result_valid=(i%2==0);
      tick();
      engine_ready = 0;
      if (i % 2 != 0) begin
        repeat (i % 3 + 1) tick();
        result_valid = 1;
        tick();
      end
      result_valid = 0;
      repeat (i % 5 + 1) begin
        if(!rsp_valid||rsp_slot!=cmd_slot||rsp_generation!=cmd_generation
            ||rsp_metadata!=(64'hfeed000000000000|64'(i))
            ||rsp_payload!=result_payload||cmd_ready)
          $fatal(1, "completion metadata/backpressure");
        tick();
      end
      rsp_ready = 1;
      tick();
      rsp_ready = 0;
      if (busy || authorized || rsp_valid) $fatal(1, "completion release");
      inject = 1;
      #1;
      if (!response_dropped) $fatal(1, "duplicate response");
      tick();
      inject = 0;
      completed++;
    end
    for (int stage = 0; stage < 4; stage++) begin
      cmd_valid=1;
      head_valid=0;
      head_safe=0;
      tick();
      cmd_valid = 0;
      if (stage > 0) begin
        head_valid=1;
        head_safe=1;
        head_slot=cmd_slot;
        head_generation=cmd_generation;
        tick();
        head_valid = 0;
      end
      if (stage > 1) begin
        engine_ready = 1;
        tick();
        engine_ready = 0;
      end
      if (stage > 2) begin
        result_tag=engine_tag;
        result_payload=32'h87654321;
        result_valid=1;
        tick();
        result_valid = 0;
      end
      // A delayed external reply can overlap reset. No handshake may escape
      // reset, and the old reply must drain while the bridge is empty before
      // the identity is reused. Reset alone does not flush an external fabric.
      inject_tag={cmd_generation,cmd_slot};
      inject=1;
      reset=1;
      cmd_valid=1;
      rsp_ready=1;
      head_valid=1;
      head_safe=1;
      #1;
      if(cmd_ready||vpu_cmd_valid||vpu_authorize_valid||vpu_kill_valid
          ||rsp_valid||vpu_rsp_ready||response_dropped)
        $fatal(1, "handshake escaped reset");
      tick();
      reset=0;
      cmd_valid=0;
      rsp_ready=0;
      head_valid=0;
      head_safe=0;
      if (busy || authorized || rsp_valid || engine_valid) $fatal(1, "paired reset boundary");
      #1;
      if (!response_dropped || !vpu_rsp_ready || rsp_valid)
        $fatal(1, "pre-reset reply was not discarded while empty");
      tick();
      inject=0;
      // Reuse is now safe in this model: the only external reply has drained.
      cmd_valid=1;
      kill_valid=1;
      kill_slot=cmd_slot;
      kill_generation=cmd_generation;
      #1;
      if (!cmd_ready || !cancelled) $fatal(1, "post-reset admission/cancellation");
      tick();
      cmd_valid=0;
      kill_valid=0;
      if (busy || authorized || rsp_valid) $fatal(1, "post-reset cancellation leaked owner");
    end
    if (completed == 0 || killed == 0 || dropped == 0) $fatal(1, "empty coverage");
    $display(
        "PASS core_adapter RobBits=%0d GenerationBits=%0d completed=%0d cancelled=%0d dropped=%0d resets=4 reset_drains=4 reset_reuse_cancels=4",
        RobBits, GenerationBits, completed, killed, dropped);
    $finish;
  end
endmodule

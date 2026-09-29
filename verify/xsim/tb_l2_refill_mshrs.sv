module tb_l2_refill_mshrs #(
    parameter int XLEN = 64
);
  localparam int NumMshrs = XLEN == 64 ? 7 : 5;
  localparam int ID_W = 4;
  localparam int LineWords = 64 / (XLEN / 8);
  logic clock = 1'b0;
  logic reset = 1'b1;
  logic alloc_valid = 1'b0;
  logic alloc_ready;
  logic alloc_reload = 1'b0;
  logic [2:0] alloc_slot = '0;
  logic retry_valid = 1'b0;
  logic [2:0] retry_slot = '0;
  logic [XLEN-1:0] alloc_addr = '0;
  logic [ID_W-1:0] alloc_inner_id = '0;
  logic [7:0] alloc_inner_len = '0;
  logic [2:0] alloc_inner_size = '0;
  logic [1:0] alloc_inner_burst = 2'b01;
  logic [3:0] alloc_cache = 4'hf;
  logic outer_arvalid;
  logic outer_arready = 1'b1;
  logic [XLEN-1:0] outer_araddr;
  logic [ID_W-1:0] outer_arid;
  logic [7:0] outer_arlen;
  logic [2:0] outer_arsize;
  logic [1:0] outer_arburst;
  logic [3:0] outer_arcache;
  logic outer_rvalid = 1'b0;
  logic outer_rready;
  logic outer_store_ready = 1'b1;
  logic [$clog2(LineWords)-1:0] outer_rbeat;
  logic [ID_W-1:0] outer_rid = '0;
  logic [XLEN-1:0] outer_rdata = '0;
  logic [1:0] outer_rresp = '0;
  logic outer_rlast = 1'b0;
  logic [NumMshrs-1:0] slot_valid;
  logic [NumMshrs-1:0] slot_done;
  logic [NumMshrs-1:0] slot_critical_ready;
  logic [LineWords-1:0] slot_beat_valid[NumMshrs];
  logic [1:0] slot_resp[NumMshrs];
  logic retire_valid = 1'b0;
  logic [2:0] retire_slot = '0;
  logic [LineWords-1:0] retire_beat_valid;
  logic [511:0] retire_line;
  logic [1:0] retire_resp;
  logic [XLEN-1:0] retire_addr;
  logic [ID_W-1:0] retire_inner_id;
  logic [7:0] retire_inner_len;
  logic [2:0] retire_inner_size;
  logic [1:0] retire_inner_burst;
  logic [3:0] retire_cache;
  logic [NumMshrs-1:0] ar_seen = '0;

  rapt_l2_refill_mshrs #(
      .XLEN    (XLEN),
      .NumMshrs(NumMshrs)
  ) dut (
      .*
  );
  always #5 clock = ~clock;
  `include "tb_common.svh"

  always_ff @(posedge clock) begin
    if (reset) ar_seen <= '0;
    else if (outer_arvalid && outer_arready) ar_seen[outer_arid[2:0]] <= 1'b1;
  end

  initial begin
    tick(3);
    reset = 1'b0;
    for (int slot = 0; slot < NumMshrs; slot++) begin
      alloc_valid = 1'b1;
      alloc_slot = 3'(slot);
      alloc_addr = XLEN'('h8000_0000 + slot * 64);
      alloc_inner_id = ID_W'(slot + 8);
      alloc_inner_len = 8'(slot);
      alloc_inner_size = 3'($clog2(XLEN / 8));
      #1;
      check(alloc_ready, "refill context was unavailable");
      tick(1);
    end
    alloc_valid = 1'b0;
    tick(1);
    check(ar_seen == '1 && slot_valid == '1, "independent outer ARs were not issued");
    check(outer_arlen == 8'(LineWords - 1) && outer_arsize == 3'($clog2(XLEN / 8
          )) && outer_arburst == 2'b01, "outer refill geometry was not a 64-byte INCR line");

    // Return one beat per slot in reverse order on each round. Each RID has
    // its own fill counter, so all lines must remain independent.
    for (int beat = 0; beat < LineWords; beat++) begin
      for (int slot = NumMshrs - 1; slot >= 0; slot--) begin
        outer_rvalid = 1'b1;
        outer_rid = ID_W'(slot);
        outer_rdata = (XLEN'(slot) << 16) | XLEN'(beat);
        outer_rresp = slot == 3 && beat == 2 ? 2'b10 : 2'b00;
        outer_rlast = beat == LineWords - 1;
        if (beat == 0 && slot == NumMshrs - 1) begin
          outer_store_ready = 1'b0;
          #1;
          check(!outer_rready && outer_rbeat == '0,
                "bank backpressure did not hold the first outer beat");
          tick(1);
          outer_store_ready = 1'b1;
        end
        #1;
        check(outer_rready && outer_rbeat == $clog2(LineWords)'(beat),
              "interleaved RID lost its allocated context or beat index");
        tick(1);
      end
      if (beat == 0) begin
        for (int slot = 0; slot < NumMshrs; slot++) begin
          retire_slot = 3'(slot);
          #1;
          check(retire_beat_valid == LineWords'(1) && retire_line[0+:XLEN] == (XLEN'(slot) << 16),
                "first refill beat was unavailable before line completion");
          check(slot_beat_valid[slot] == LineWords'(1),
                "per-slot received-beat bitmap missed its first word");
        end
      end
    end
    outer_rvalid = 1'b0;
    #1;
    check(slot_done == '1, "some interleaved fills did not complete");
    for (int slot = 0; slot < NumMshrs; slot++)
    check(slot_critical_ready[slot] == (slot != 3),
          "successful critical words were not retained, or error was exposed early");
    for (int slot = 0; slot < NumMshrs; slot++) begin
      retire_slot = 3'(slot);
      #1;
      check(
          retire_addr == XLEN'('h8000_0000 + slot * 64)
                && retire_inner_id == ID_W'(slot + 8) && retire_inner_len == 8'(slot),
          "inner request metadata was not retained by RID");
      check(retire_resp == (slot == 3 ? 2'b10 : 2'b00), "refill error was not retained per MSHR");
      check(slot_resp[slot] == retire_resp, "per-slot response did not match selected refill");
      check(retire_beat_valid == '1, "completed refill did not mark all beats valid");
      check(slot_beat_valid[slot] == '1, "completed per-slot beat bitmap was incomplete");
      for (int beat = 0; beat < LineWords; beat++)
      check(retire_line[beat*XLEN+:XLEN] == ((XLEN'(slot) << 16) | XLEN'(beat)),
            "refill data was corrupted by interleaving");
      if (slot == 0) begin
        // A BOOM MSHR retains its same-set secondary lists while changing
        // tags. Reuse the completed outer context without freeing its RID.
        retire_valid = 1'b0;
        alloc_slot = 3'd0;
        alloc_addr = XLEN'('h8001_0000);
        alloc_inner_id = 4'd15;
        alloc_inner_len = '0;
        outer_arready = 1'b0;
        alloc_reload = 1'b1;
        alloc_valid = 1'b1;
        #1;
        check(alloc_ready, "completed refill context could not reload");
        tick(1);
        alloc_valid  = 1'b0;
        alloc_reload = 1'b0;
        #1;
        check(slot_valid[0] && !slot_done[0] && retire_beat_valid == '0,
              "reloaded context retained old refill status");
        check(slot_beat_valid[0] == '0,
              "reloaded context retained the previous line's received-beat bitmap");
        continue;
      end
      retire_valid = 1'b1;
      tick(1);
      retire_valid = 1'b0;
    end
    #1;
    check(slot_valid == NumMshrs'(1) && slot_done == '0, "retired refill slots were not freed");
    for (int cycle = 0; cycle < 8 && !outer_arvalid; cycle++) tick(1);
    check(outer_arvalid && outer_arid == 4'd0 && outer_araddr == XLEN'('h8001_0000),
          "reloaded context did not issue a fresh outer AR");
    outer_arready = 1'b1;
    tick(1);
    for (int beat = 0; beat < LineWords; beat++) begin
      outer_rvalid = 1'b1;
      outer_rid = 4'd0;
      outer_rdata = XLEN'('h9000_0000 + beat);
      outer_rresp = beat == 1 ? 2'b10 : 2'b00;
      outer_rlast = beat == LineWords - 1;
      tick(1);
    end
    outer_rvalid = 1'b0;
    retire_slot  = 3'd0;
    #1;
    check(
        slot_done[0] && retire_addr == XLEN'('h8001_0000)
          && retire_inner_id == 4'd15 && retire_resp == 2'b10,
        "reloaded context did not retain its new request and refill error");
    retry_slot  = 3'd0;
    retry_valid = 1'b1;
    tick(1);
    retry_valid = 1'b0;
    #1;
    check(
        slot_valid[0] && !slot_done[0] && slot_beat_valid[0] == '0
              && slot_resp[0] == 2'b00 && retire_addr == XLEN'('h8001_0000)
              && retire_inner_id == 4'd15,
        "retry did not clear the failed fill while preserving its request");
    for (int cycle = 0; cycle < 8 && !outer_arvalid; cycle++) tick(1);
    check(outer_arvalid && outer_arid == 4'd0 && outer_araddr == XLEN'('h8001_0000),
          "retry did not reissue the same outer line");
    tick(1);
    for (int beat = 0; beat < LineWords; beat++) begin
      outer_rvalid = 1'b1;
      outer_rid = 4'd0;
      outer_rdata = XLEN'('ha000_0000 + beat);
      outer_rresp = 2'b00;
      outer_rlast = beat == LineWords - 1;
      tick(1);
    end
    outer_rvalid = 1'b0;
    #1;
    check(
        slot_done[0] && slot_beat_valid[0] == '1 && retire_resp == 2'b00
              && retire_line[0+:XLEN] == XLEN'('ha000_0000),
        "successful retry retained the failed line's data or error");
    retire_valid = 1'b1;
    tick(1);
    retire_valid = 1'b0;
    #1;
    check(slot_valid == '0 && slot_done == '0, "retired refill slots were not freed");
    $display("PASS: RV%0d BOOM %0d-MSHR interleaved refill, reload, and ID remapping", XLEN,
             NumMshrs);
    $finish;
  end
endmodule

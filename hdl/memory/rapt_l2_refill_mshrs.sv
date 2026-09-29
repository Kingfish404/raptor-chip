// Independent outer-memory refill contexts for BOOM's seven L2 MSHRs.
// The outer AXI ID is the context index; the original inner ID is retained
// for response routing. Different fills may return interleaved beats.
module rapt_l2_refill_mshrs #(
    parameter int XLEN = 64,
    parameter int ID_W = 4,
    parameter int LineBytes = 64,
    parameter int NumMshrs = 7,
    parameter int MshrBits = (NumMshrs <= 1) ? 1 : $clog2(NumMshrs),
    parameter int LineWords = LineBytes / (XLEN / 8),
    parameter int WordBits = (LineWords <= 1) ? 1 : $clog2(LineWords)
) (
    input logic clock,
    input logic reset,
    input logic alloc_valid,
    output logic alloc_ready,
    // A completed context may be reloaded in place after its old line has
    // been installed. Its secondary lists remain attached to this slot.
    input logic alloc_reload,
    input logic [MshrBits-1:0] alloc_slot,
    // Reissue a completed outer refill without changing its inner request
    // or secondary-list ownership. A nested C Release retains its data
    // until this retry has filled the reserved way successfully.
    input logic retry_valid,
    input logic [MshrBits-1:0] retry_slot,
    input logic [XLEN-1:0] alloc_addr,
    input logic [ID_W-1:0] alloc_inner_id,
    input logic [7:0] alloc_inner_len,
    input logic [2:0] alloc_inner_size,
    input logic [1:0] alloc_inner_burst,
    input logic [3:0] alloc_cache,
    output logic outer_arvalid,
    input logic outer_arready,
    output logic [XLEN-1:0] outer_araddr,
    output logic [ID_W-1:0] outer_arid,
    output logic [7:0] outer_arlen,
    output logic [2:0] outer_arsize,
    output logic [1:0] outer_arburst,
    output logic [3:0] outer_arcache,
    input logic outer_rvalid,
    output logic outer_rready,
    input logic outer_store_ready,
    input logic [ID_W-1:0] outer_rid,
    output logic [WordBits-1:0] outer_rbeat,
    input logic [XLEN-1:0] outer_rdata,
    input logic [1:0] outer_rresp,
    input logic outer_rlast,
    output logic [NumMshrs-1:0] slot_valid,
    output logic [NumMshrs-1:0] slot_done,
    output logic [NumMshrs-1:0] slot_critical_ready,
    output logic [LineWords-1:0] slot_beat_valid[NumMshrs],
    output logic [1:0] slot_resp[NumMshrs],
    input logic retire_valid,
    input logic [MshrBits-1:0] retire_slot,
    output logic [LineWords-1:0] retire_beat_valid,
    output logic [LineBytes*8-1:0] retire_line,
    output logic [1:0] retire_resp,
    output logic [XLEN-1:0] retire_addr,
    output logic [ID_W-1:0] retire_inner_id,
    output logic [7:0] retire_inner_len,
    output logic [2:0] retire_inner_size,
    output logic [1:0] retire_inner_burst,
    output logic [3:0] retire_cache
);
  if ((XLEN != 32 && XLEN != 64) || LineBytes < XLEN / 8
      || LineBytes % (XLEN / 8) != 0 || (LineWords & (LineWords - 1)) != 0
      || NumMshrs < 3 || NumMshrs > (1 << ID_W))
    $error("invalid L2 refill MSHR geometry");

  logic [NumMshrs-1:0] ar_sent;
  logic [WordBits-1:0] fill_word[NumMshrs];
  logic [WordBits-1:0] critical_word[NumMshrs];
  logic [LineWords-1:0] beat_valid[NumMshrs];
  logic [LineBytes*8-1:0] line_buf[NumMshrs];
  logic [1:0] fill_resp[NumMshrs];
  logic [XLEN-1:0] addr[NumMshrs];
  logic [ID_W-1:0] inner_id[NumMshrs];
  logic [7:0] inner_len[NumMshrs];
  logic [2:0] inner_size[NumMshrs];
  logic [1:0] inner_burst[NumMshrs];
  logic [3:0] cache[NumMshrs];
  logic [MshrBits-1:0] last_issue, issue_slot;
  logic r_fire;

  assign alloc_ready = int'(alloc_slot) < NumMshrs
      && (!slot_valid[int'(alloc_slot)]
          || (alloc_reload && slot_done[int'(alloc_slot)]));
  assign outer_araddr = {
    addr[int'(issue_slot)][XLEN-1:$clog2(LineBytes)], {$clog2(LineBytes) {1'b0}}
  };
  assign outer_arid = ID_W'(issue_slot);
  assign outer_arlen = 8'(LineWords - 1);
  assign outer_arsize = 3'($clog2(XLEN / 8));
  assign outer_arburst = 2'b01;
  assign outer_arcache = cache[int'(issue_slot)];
  always_comb begin
    outer_rready = 1'b0;
    outer_rbeat  = '0;
    for (int slot = 0; slot < NumMshrs; slot++) begin
      if (outer_rid == ID_W'(slot)) begin
        outer_rready = slot_valid[slot] && ar_sent[slot] && !slot_done[slot] && outer_store_ready;
        outer_rbeat  = fill_word[slot];
      end
    end
  end
  assign r_fire = outer_rvalid && outer_rready;

  // The selected line and beat-valid mask may be inspected before retire.
  // This permits early critical-beat return while later beats are in flight.
  assign retire_beat_valid = beat_valid[int'(retire_slot)];
  assign retire_line = line_buf[int'(retire_slot)];
  assign retire_resp = fill_resp[int'(retire_slot)];
  assign retire_addr = addr[int'(retire_slot)];
  assign retire_inner_id = inner_id[int'(retire_slot)];
  assign retire_inner_len = inner_len[int'(retire_slot)];
  assign retire_inner_size = inner_size[int'(retire_slot)];
  assign retire_inner_burst = inner_burst[int'(retire_slot)];
  assign retire_cache = cache[int'(retire_slot)];
  for (genvar slot = 0; slot < NumMshrs; slot++) begin : g_critical_ready
    assign slot_beat_valid[slot] = beat_valid[slot];
    assign slot_resp[slot] = fill_resp[slot];
    assign slot_critical_ready[slot] = slot_valid[slot]
        && beat_valid[slot][critical_word[slot]] && fill_resp[slot] == 2'b00;
  end

  // Use a round-robin AR grant so a ready outer bus sees all pending slots.
  always_comb begin
    int candidate;
    outer_arvalid = 1'b0;
    issue_slot = '0;
    for (int offset = 1; offset <= NumMshrs; offset++) begin
      candidate = int'(last_issue) + offset;
      if (candidate >= NumMshrs) candidate -= NumMshrs;
      if (!outer_arvalid && slot_valid[candidate] && !ar_sent[candidate]) begin
        outer_arvalid = 1'b1;
        issue_slot = MshrBits'(candidate);
      end
    end
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      slot_valid <= '0;
      slot_done <= '0;
      ar_sent <= '0;
      last_issue <= MshrBits'(NumMshrs - 1);
      for (int slot = 0; slot < NumMshrs; slot++) begin
        fill_word[slot] <= '0;
        critical_word[slot] <= '0;
        beat_valid[slot] <= '0;
        fill_resp[slot] <= '0;
      end
    end else begin
      if (alloc_valid && alloc_ready) begin
        slot_valid[int'(alloc_slot)] <= 1'b1;
        slot_done[int'(alloc_slot)] <= 1'b0;
        ar_sent[int'(alloc_slot)] <= 1'b0;
        fill_word[int'(alloc_slot)] <= '0;
        critical_word[int'(alloc_slot)] <= WordBits'(alloc_addr >> $clog2(XLEN / 8));
        beat_valid[int'(alloc_slot)] <= '0;
        fill_resp[int'(alloc_slot)] <= 2'b00;
        addr[int'(alloc_slot)] <= alloc_addr;
        inner_id[int'(alloc_slot)] <= alloc_inner_id;
        inner_len[int'(alloc_slot)] <= alloc_inner_len;
        inner_size[int'(alloc_slot)] <= alloc_inner_size;
        inner_burst[int'(alloc_slot)] <= alloc_inner_burst;
        cache[int'(alloc_slot)] <= alloc_cache;
      end
      if (retry_valid) begin
        slot_done[int'(retry_slot)] <= 1'b0;
        ar_sent[int'(retry_slot)] <= 1'b0;
        fill_word[int'(retry_slot)] <= '0;
        beat_valid[int'(retry_slot)] <= '0;
        fill_resp[int'(retry_slot)] <= 2'b00;
      end
      if (outer_arvalid && outer_arready) begin
        ar_sent[int'(issue_slot)] <= 1'b1;
        last_issue <= issue_slot;
      end
      if (r_fire) begin
        line_buf[int'(outer_rid)][int'(fill_word[int'(outer_rid)])*XLEN+:XLEN] <= outer_rdata;
        beat_valid[int'(outer_rid)][int'(fill_word[int'(outer_rid)])] <= 1'b1;
        if (outer_rresp != 2'b00) fill_resp[int'(outer_rid)] <= outer_rresp;
        if (outer_rlast) slot_done[int'(outer_rid)] <= 1'b1;
        else fill_word[int'(outer_rid)] <= fill_word[int'(outer_rid)] + 1'b1;
      end
      if (retire_valid) begin
        slot_valid[int'(retire_slot)] <= 1'b0;
        slot_done[int'(retire_slot)]  <= 1'b0;
      end
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clock) begin
    if (!reset) begin
      if (alloc_valid) assert (int'(alloc_slot) < NumMshrs && alloc_ready);
      if (alloc_valid && alloc_reload) begin
        assert (slot_valid[int'(alloc_slot)] && slot_done[int'(alloc_slot)]);
        assert (!(retire_valid && retire_slot == alloc_slot));
      end
      if (retry_valid)
        assert (int'(retry_slot) < NumMshrs && slot_valid[int'(retry_slot)]
                && slot_done[int'(retry_slot)] && fill_resp[int'(retry_slot)] != 2'b00);
      if (outer_rvalid) begin
        assert (int'(outer_rid) < NumMshrs);
        if (int'(outer_rid) < NumMshrs)
          assert (slot_valid[int'(outer_rid)] && ar_sent[int'(outer_rid)]
                  && !slot_done[int'(outer_rid)]);
        if (outer_store_ready) assert (outer_rready);
      end
      if (r_fire) assert (outer_rlast == (fill_word[int'(outer_rid)] == WordBits'(LineWords - 1)));
      if (retire_valid) assert (slot_valid[int'(retire_slot)] && slot_done[int'(retire_slot)]);
    end
  end
`endif
endmodule

`include "rapt.svh"
// Physical-line miss table and refill buffers. Requests replay through L1D
// (including translation/PMP) before consuming data; no speculative ROB tags
// are retained here. Completed lines stay until replaced or invalidated.
module rapt_l1d_mshr #(
    parameter int Xlen = `RAPT_XLEN,
    parameter int Entries = 2,
    parameter int LineBytes = `RAPT_CACHE_LINE_BYTES,
    parameter int Words = LineBytes / (Xlen / 8),
    parameter int WordBits = $clog2(Words),
    parameter int OffsetBits = $clog2(LineBytes)
) (
    input logic clock,
    reset,
    invalidate,
    // Stores still drain issued refills before reaching this port. Invalidate
    // only their physical line; unrelated completed buffers remain reusable.
    input logic invalidate_line,
    input logic [Xlen-1:0] invalidate_addr,
    output logic fill_valid,
    input logic fill_ready,
    output logic [Xlen-1:0] fill_addr,
    output logic [Words-1:0] fill_mask,
    output logic [Words*Xlen-1:0] fill_data,
    input logic lookup_valid,
    cache_hit,
    input logic [Xlen-1:0] lookup_addr,
    input logic [7:0] lookup_version,
    output logic lookup_ready,
    lookup_error,
    lookup_wait,
    lookup_buffered,
    output logic [Xlen-1:0] lookup_data,
    output logic busy,
    wake,
    output logic req_valid,
    output logic [1:0] req_id,
    output logic [Xlen-1:0] req_addr,
    input logic req_ready,
    input logic rsp_valid,
    input logic [1:0] rsp_id,
    input logic [Xlen-1:0] rsp_data,
    input logic rsp_error,
    rsp_last
);
  if (!(Entries >= 1 && Entries <= 4 && Words >= 2 && (Words & (Words - 1)) == 0))
    initial $fatal(1, "Invalid L1D MSHR geometry");
  localparam int IdBits = Entries > 1 ? $clog2(Entries) : 1;
  logic [Entries-1:0] valid, sent, done, killed, consumed, installed;
  logic [Xlen-1:OffsetBits] tag[Entries];
  logic [7:0] version[Entries];
  logic [Xlen-1:0] data[Entries][Words];
  logic [Words-1:0] errors[Entries], received[Entries], waiting[Entries];
  logic [Entries-1:0] kill_line;
  logic [IdBits-1:0] fill_id;
  logic [WordBits-1:0] beat[Entries];
  logic match_found, free_found, send_found;
  logic [1:0] match_id, free_id;
  logic [1:0] replace_q;
  logic allocate;
  always_comb begin
    fill_valid = 0;
    fill_id = '0;
    for (int i = Entries - 1; i >= 0; i--) begin
      kill_line[i] = invalidate_line && tag[i] == invalidate_addr[Xlen-1:OffsetBits];
      if (valid[i] && done[i] && !killed[i] && !installed[i] && !invalidate && !kill_line[i]) begin
        fill_valid = 1;
        fill_id = IdBits'(i);
      end
    end
    fill_addr = {tag[fill_id], {OffsetBits{1'b0}}};
    fill_mask = ~errors[fill_id];
    for (int w = 0; w < Words; w++) fill_data[w*Xlen+:Xlen] = data[fill_id][w];
  end
  always_comb begin
    match_found = 0;
    free_found = 0;
    send_found = 0;
    match_id = 0;
    free_id = 0;
    req_id = 0;
    for (int i = Entries - 1; i >= 0; i--) begin
      if (valid[i] && !killed[i] && !kill_line[i]
          && tag[i] == lookup_addr[Xlen-1:OffsetBits]
          && version[i] == lookup_version) begin
        match_found = 1;
        match_id = 2'(i);
      end
      if (!valid[i]) begin
        free_found = 1;
        free_id = 2'(i);
      end
      if (valid[i] && !sent[i] && !killed[i]) begin
        send_found = 1;
        req_id = 2'(i);
      end
    end
    // Once installed, the cache owns every successful word. Replays may
    // have completed on a cache/B hit without consuming this buffer, so
    // waiting for consumed here can permanently exhaust an idle table.
    if (!free_found) begin
      for (int n = Entries - 1; n >= 0; n--) begin
        if (done[(int'(replace_q)+n)%Entries] && installed[(int'(replace_q)+n)%Entries]) begin
          free_found = 1;
          free_id = 2'((int'(replace_q)+n)%Entries);
        end
      end
    end
  end
  assign lookup_buffered = match_found
      && received[IdBits'(match_id)][lookup_addr[OffsetBits-1:$clog2(
      Xlen/8
  )]] && !invalidate && !invalidate_line;
  always_comb begin
    busy = |(valid & ~done);
    lookup_ready = lookup_valid && !cache_hit && lookup_buffered;
    lookup_error = lookup_ready && errors[IdBits'(match_id)][lookup_addr[OffsetBits-1:$clog2(Xlen/8)]];
    lookup_data = data[IdBits'(match_id)][lookup_addr[OffsetBits-1:$clog2(Xlen/8)]];
    allocate = lookup_valid && !cache_hit && !match_found && free_found && !invalidate && !invalidate_line;
    // A full table also releases the requester; a completion will wake it.
    lookup_wait = lookup_valid && !cache_hit && !lookup_ready && !invalidate && !invalidate_line;
    req_valid = send_found && !invalidate && !invalidate_line;
    req_addr = {tag[IdBits'(req_id)], {OffsetBits{1'b0}}};
    // Wake for a demanded beat, capacity becoming available, or invalidation.
    // Undemanded intermediate beats do not cause global replay storms.
    wake = invalidate || invalidate_line || (fill_valid && fill_ready)
        || (rsp_valid && (rsp_last || waiting[IdBits'(rsp_id)][beat[IdBits'(rsp_id)]]))
        || ((lookup_ready || (lookup_valid && cache_hit && match_found))
            && !consumed[IdBits'(match_id)]);
  end
  always_ff @(posedge clock) begin
    if (reset) begin
      valid <= '0;
      sent <= '0;
      done <= '0;
      killed <= '0;
      consumed <= '0;
      installed <= '0;
      replace_q <= '0;
    end else begin
      if (fill_valid && fill_ready) installed[fill_id] <= 1;
      if (lookup_wait && match_found)
        waiting[IdBits'(match_id)][lookup_addr[OffsetBits-1:$clog2(Xlen/8)]] <= 1;
      if (lookup_ready || (lookup_valid && cache_hit && match_found))
        consumed[IdBits'(match_id)] <= 1;
      if (allocate) begin
        valid[IdBits'(free_id)] <= 1;
        sent[IdBits'(free_id)] <= 0;
        done[IdBits'(free_id)] <= 0;
        consumed[IdBits'(free_id)] <= 0;
        killed[IdBits'(free_id)] <= 0;
        tag[IdBits'(free_id)] <= lookup_addr[Xlen-1:OffsetBits];
        version[IdBits'(free_id)] <= lookup_version;
        beat[IdBits'(free_id)] <= '0;
        errors[IdBits'(free_id)] <= '0;
        received[IdBits'(free_id)] <= '0;
        waiting[IdBits'(free_id)] <= Words'(1) << lookup_addr[OffsetBits-1:$clog2(Xlen/8)];
        installed[IdBits'(free_id)] <= 0;
        replace_q <= int'(free_id) == Entries-1 ? 2'd0 : free_id + 2'd1;
      end
      if (req_valid && req_ready) sent[IdBits'(req_id)] <= 1;
      if (rsp_valid && int'(rsp_id) < Entries && valid[IdBits'(rsp_id)] && sent[IdBits'(rsp_id)]) begin
        data[IdBits'(rsp_id)][beat[IdBits'(rsp_id)]] <= rsp_data;
        received[IdBits'(rsp_id)][beat[IdBits'(rsp_id)]] <= 1;
        waiting[IdBits'(rsp_id)][beat[IdBits'(rsp_id)]] <= 0;
        errors[IdBits'(rsp_id)][beat[IdBits'(rsp_id)]] <= rsp_error;
        beat[IdBits'(rsp_id)] <= beat[IdBits'(rsp_id)] + 1'b1;
        if (rsp_last) begin
          done[IdBits'(rsp_id)] <= !killed[IdBits'(rsp_id)] && !invalidate;
          if (killed[IdBits'(rsp_id)] || invalidate) valid[IdBits'(rsp_id)] <= 0;
        end
      end
      begin
        for (int i = 0; i < Entries; i++)
        if (invalidate || kill_line[i]) begin
          killed[i] <= 1;
          done[i] <= 0;
          if (!sent[i] || done[i] || (rsp_valid && rsp_last && rsp_id == 2'(i))) valid[i] <= 0;
        end
      end
    end
  end
  `RAPT_SVA_IMPLY(clock, reset, MSHR_STORE_DRAINED, invalidate_line, !busy)
  `RAPT_SVA_IMPLY(
      clock, reset, MSHR_RESPONSE_OWNER, rsp_valid,
      int'(rsp_id) < Entries && valid[IdBits'(rsp_id)] && sent[IdBits'(rsp_id)] && !done[IdBits'(rsp_id)])
  `RAPT_SVA_IMPLY(clock, reset, MSHR_RESPONSE_LENGTH, rsp_valid,
                  rsp_last == (&beat[IdBits'(rsp_id)]))
  `RAPT_SVA_IMPLY(clock, reset, MSHR_WAIT_HAS_PROGRESS, lookup_wait && !allocate,
                  busy || |(valid & done & ~installed))
`ifndef SYNTHESIS
`ifdef RAPT_AXI_OBSERVE
  // Handshake evidence at the cache/bus boundary, distinct from off-chip AR.
  always_ff @(posedge clock)
    if (!reset) begin
      if (req_valid && req_ready) $display("MSHR_OBS REQ %0d %h", req_id, req_addr);
      if (rsp_valid && rsp_last) $display("MSHR_OBS DONE %0d", rsp_id);
    end
`endif
`endif
endmodule

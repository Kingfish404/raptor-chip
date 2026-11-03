`include "rapt.svh"
// Physical-line miss table and refill buffers. Requests replay through L1D
// (including translation/PMP) before consuming data; no speculative ROB tags
// are retained here. Completed lines stay until replaced or invalidated.
// With StoreMerge a committed store to a missing line is acknowledged here: its
// bytes wait in the entry and win over the refill. Such an entry holds the only
// copy of those bytes, so nothing but its own installation can retire it.
module rapt_l1d_mshr #(
    parameter int Xlen = `RAPT_XLEN,
    parameter int Entries = 2,
    // A consumer that already excludes line invalidation from its fill
    // acceptance can keep the invalidating address out of payload selection.
    parameter bit StallFillOnLineInvalidate = 1'b0,
    parameter bit StoreMerge = 1'b0,
    parameter int LineBytes = `RAPT_CACHE_LINE_BYTES,
    parameter int Words = LineBytes / (Xlen / 8),
    parameter int WordBits = $clog2(Words),
    parameter int OffsetBits = $clog2(LineBytes)
) (
    input logic clock,
    reset,
    invalidate,
    // Stores drain issued refills; eviction/Release may invalidate a copy
    // while unrelated refills remain live. Accepted killed owners still
    // retain their ID through RLAST below.
    input logic invalidate_line,
    input logic [Xlen-1:0] invalidate_addr,
    output logic fill_valid,
    input logic fill_ready,
    output logic [Xlen-1:0] fill_addr,
    output logic [Words-1:0] fill_mask,
    output logic [Words*Xlen-1:0] fill_data,
    output logic [Words-1:0] fill_dirty,
    // Acknowledged store bytes cannot be merged because their word failed.
    output logic fill_store_lost,
    output logic fill_owned,
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
    rsp_last,
    // A store offered at store_addr kills installed copies of its line. On
    // store_fire it joins every live entry of the line, or takes a free entry
    // with store_alloc. The controller never fires with rsp_valid set.
    input logic store_valid,
    input logic store_fire,
    input logic store_alloc,
    input logic [Xlen-1:0] store_addr,
    input logic [Xlen-1:0] store_data,
    input logic [Xlen/8-1:0] store_strobe,
    output logic store_match,
    output logic store_free,
    // An uninstalled entry holds store bytes / holds them for lookup_addr.
    output logic store_pending,
    output logic lookup_store_match
);
  if (!(Entries >= 1 && Entries <= 4 && Words >= 2 && (Words & (Words - 1)) == 0)) begin : g_invalid_geometry
    initial $fatal(1, "Invalid L1D MSHR geometry");
  end
  localparam int IdBits = Entries > 1 ? $clog2(Entries) : 1;
  logic [Entries-1:0] valid, sent, done, killed, consumed, installed;
  logic [Xlen-1:OffsetBits] tag[Entries];
  logic [7:0] version[Entries];
  logic [Xlen-1:0] data[Entries][Words];
  logic [Words-1:0] errors[Entries], received[Entries], waiting[Entries];
  logic [Entries-1:0] kill_line, kill_now, store_hit;
  logic [Entries-1:0] store_dirty;
  logic [Xlen/8-1:0] store_mask[Entries][Words];
  logic [Xlen/8-1:0] data_write[Entries][Words];
  logic [Xlen-1:0] data_in;
  logic [WordBits-1:0] store_word;
  logic [Words-1:0] entry_dirty[Entries];
  assign store_word = store_addr[OffsetBits-1:$clog2(Xlen/8)];
  logic [IdBits-1:0] fill_id;
  logic [WordBits-1:0] beat[Entries];
  logic match_found, free_found, send_found;
  logic [1:0] match_id, free_id;
  logic [1:0] replace_q;
  logic allocate;
  // Hold the installation owner before exposing its line to the tag and
  // victim probes. Installed/killed arbitration may change this register,
  // but cannot select a different refill address in the consumer's cycle.
  logic fill_pending;
  logic [Entries-1:0] fill_candidate;
  always_comb begin
    store_match = 1'b0;
    store_pending = 1'b0;
    lookup_store_match = 1'b0;
    for (int i = 0; i < Entries; i++) begin
      kill_line[i] = (invalidate_line && tag[i] == invalidate_addr[Xlen-1:OffsetBits])
          || (StoreMerge && store_valid && installed[i]
              && tag[i] == store_addr[Xlen-1:OffsetBits]);
      store_hit[i] = StoreMerge && valid[i] && !killed[i] && !installed[i]
          && tag[i] == store_addr[Xlen-1:OffsetBits];
      store_match |= store_hit[i];
      store_pending |= store_dirty[i];
      lookup_store_match |= store_dirty[i] && tag[i] == lookup_addr[Xlen-1:OffsetBits];
      // A store joining in this cycle protects its entry like earlier bytes.
      kill_now[i] = kill_line[i]
          || (invalidate && !store_dirty[i] && !(store_fire && store_hit[i]));
      // Look ahead through the last accepted beat. The owner becomes valid
      // on the same edge as done/data, so quiescence never sees an empty
      // cycle between the bus drain and a pending installation.
      fill_candidate[i] = valid[i] && !killed[i] && !installed[i]
          && (done[i] || (rsp_valid && rsp_last && sent[i] && rsp_id == 2'(i)))
          && !kill_now[i] && !(fill_valid && fill_ready && fill_id == IdBits'(i));
    end
    fill_addr = {tag[fill_id], {OffsetBits{1'b0}}};
    // A failed beat leaves its word undefined unless stores wrote every byte.
    // Never install the mix: loads refetch and fault, and the lost store stops
    // the cache like a failed write response.
    for (int w = 0; w < Words; w++) begin
      fill_mask[w] = !errors[fill_id][w] || (&store_mask[fill_id][w]);
    end
    fill_dirty = entry_dirty[fill_id] & fill_mask;
    fill_store_lost = |(entry_dirty[fill_id] & ~fill_mask);
    for (int w = 0; w < Words; w++) fill_data[w*Xlen+:Xlen] = data[fill_id][w];
  end
  assign fill_owned = fill_pending;
  assign fill_valid = fill_pending && (!invalidate || store_dirty[fill_id])
      && (StallFillOnLineInvalidate ? !invalidate_line : !kill_line[fill_id]);
  always_ff @(posedge clock) begin
    if (!fill_pending || (fill_valid && fill_ready) || kill_now[fill_id]) begin
      fill_pending <= 1'b0;
      for (int i = Entries - 1; i >= 0; i--) begin
        if (fill_candidate[i]) begin
          fill_pending <= 1'b1;
          fill_id <= IdBits'(i);
        end
      end
    end
    if (reset || (!StoreMerge && invalidate)) begin
      fill_pending <= 1'b0;
      fill_id <= '0;
    end
  end
  `RAPT_SVA(clock, reset, MSHR_FILL_PENDING_COVERS_DONE,
            fill_pending == (|(valid & done & ~killed & ~installed)))
  `RAPT_SVA_IMPLY(clock, reset, MSHR_FILL_OWNER, fill_pending,
                  valid[fill_id] && done[fill_id] && !killed[fill_id] && !installed[fill_id])
  always_comb begin
    match_found = 0;
    free_found = 0;
    send_found = 0;
    match_id = 0;
    free_id = 0;
    req_id = 0;
    for (int i = Entries - 1; i >= 0; i--) begin
      // Translation is rechecked before this lookup. An old epoch's buffer is
      // refetched unless it holds store bytes that memory does not have yet.
      if (valid[i] && !killed[i] && !kill_line[i]
          && tag[i] == lookup_addr[Xlen-1:OffsetBits]
          && (version[i] == lookup_version || store_dirty[i])) begin
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
  assign store_free = free_found;
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
  // Refill beats and stores never coincide, so one shared input bus feeds
  // every entry and only the byte enables differ.
  assign data_in = StoreMerge && store_fire ? store_data : rsp_data;
  always_comb begin
    for (int i = 0; i < Entries; i++) begin
      for (int w = 0; w < Words; w++) begin
        data_write[i][w] = '0;
        if (rsp_valid && int'(rsp_id) == i && valid[i] && sent[i] && beat[i] == WordBits'(w))
          data_write[i][w] = ~store_mask[i][w];
        if (store_fire && store_word == WordBits'(w)
            && (store_hit[i] || (store_alloc && free_id == 2'(i))))
          data_write[i][w] = store_strobe;
      end
    end
  end
  always_ff @(posedge clock) begin
    if (!reset) begin
      for (int i = 0; i < Entries; i++) begin
        for (int w = 0; w < Words; w++) begin
          for (int b = 0; b < Xlen / 8; b++)
          if (data_write[i][w][b]) data[i][w][b*8+:8] <= data_in[b*8+:8];
        end
      end
    end
  end
  if (StoreMerge) begin : g_store_state
    always_ff @(posedge clock) begin
      if (reset) store_dirty <= '0;
      else begin
        if (fill_valid && fill_ready) store_dirty[fill_id] <= 1'b0;
        for (int i = 0; i < Entries; i++) begin
          if (store_fire && store_hit[i]) begin
            store_dirty[i] <= 1'b1;
            store_mask[i][store_word] <= store_mask[i][store_word] | store_strobe;
          end
        end
        if (store_fire && store_alloc) begin
          store_dirty[IdBits'(free_id)] <= 1'b1;
          for (int w = 0; w < Words; w++) store_mask[IdBits'(free_id)][w] <= '0;
          store_mask[IdBits'(free_id)][store_word] <= store_strobe;
        end else if (allocate) begin
          store_dirty[IdBits'(free_id)] <= 1'b0;
          for (int w = 0; w < Words; w++) store_mask[IdBits'(free_id)][w] <= '0;
        end
      end
    end
    always_comb begin
      for (int i = 0; i < Entries; i++) begin
        for (int w = 0; w < Words; w++) entry_dirty[i][w] = |store_mask[i][w];
      end
    end
  end else begin : g_no_store_state
    assign store_dirty = '0;
    always_comb begin
      for (int i = 0; i < Entries; i++) begin
        entry_dirty[i] = '0;
        for (int w = 0; w < Words; w++) store_mask[i][w] = '0;
      end
    end
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
      if (req_valid && req_ready) sent[IdBits'(req_id)] <= 1;
      if (rsp_valid && int'(rsp_id) < Entries && valid[IdBits'(rsp_id)] && sent[IdBits'(rsp_id)]) begin
        received[IdBits'(rsp_id)][beat[IdBits'(rsp_id)]] <= 1;
        waiting[IdBits'(rsp_id)][beat[IdBits'(rsp_id)]] <= 0;
        errors[IdBits'(rsp_id)][beat[IdBits'(rsp_id)]] <= rsp_error;
        beat[IdBits'(rsp_id)] <= beat[IdBits'(rsp_id)] + 1'b1;
        if (rsp_last) begin
          done[IdBits'(rsp_id)] <= !killed[IdBits'(rsp_id)] && !kill_now[IdBits'(rsp_id)];
          if (killed[IdBits'(rsp_id)] || kill_now[IdBits'(rsp_id)]) valid[IdBits'(rsp_id)] <= 0;
        end
      end
      begin
        for (int i = 0; i < Entries; i++)
        if (kill_now[i]) begin
          killed[i] <= 1;
          done[i] <= 0;
          if (!sent[i] || done[i] || (rsp_valid && rsp_last && rsp_id == 2'(i))) valid[i] <= 0;
        end
      end
      // Last: a store may take over an installed copy that it kills above.
      if (allocate || (store_fire && store_alloc)) begin
        valid[IdBits'(free_id)] <= 1;
        sent[IdBits'(free_id)] <= 0;
        done[IdBits'(free_id)] <= 0;
        consumed[IdBits'(free_id)] <= 0;
        killed[IdBits'(free_id)] <= 0;
        tag[IdBits'(free_id)] <= allocate ? lookup_addr[Xlen-1:OffsetBits]
            : store_addr[Xlen-1:OffsetBits];
        version[IdBits'(free_id)] <= lookup_version;
        beat[IdBits'(free_id)] <= '0;
        errors[IdBits'(free_id)] <= '0;
        received[IdBits'(free_id)] <= '0;
        waiting[IdBits'(free_id)] <= allocate
            ? Words'(1) << lookup_addr[OffsetBits-1:$clog2(Xlen/8)] : '0;
        installed[IdBits'(free_id)] <= 0;
        replace_q <= int'(free_id) == Entries-1 ? 2'd0 : free_id + 2'd1;
      end
    end
  end
  `RAPT_SVA_IMPLY(
      clock, reset, MSHR_RESPONSE_OWNER, rsp_valid,
      int'(rsp_id) < Entries && valid[IdBits'(rsp_id)] && sent[IdBits'(rsp_id)] && !done[IdBits'(rsp_id)])
`ifdef RAPT_SVA_ACTIVE
  wire response_length_matches = rsp_last == (&beat[IdBits'(rsp_id)]);
`endif
  `RAPT_SVA_IMPLY(clock, reset, MSHR_RESPONSE_LENGTH, rsp_valid, response_length_matches)
  `RAPT_SVA_IMPLY(clock, reset, MSHR_WAIT_HAS_PROGRESS, lookup_wait && !allocate,
                  busy || |(valid & done & ~installed))
  `RAPT_SVA(clock, reset, MSHR_STORE_BYTES_LIVE,
            (store_dirty & ~(valid & ~killed & ~installed)) == '0)
  `RAPT_SVA_IMPLY(clock, reset, MSHR_STORE_EXCLUDES_REFILL_BEAT, store_fire,
                  !rsp_valid && !allocate)
  `RAPT_SVA_IMPLY(clock, reset, MSHR_STORE_NOT_KILLED, store_fire, (store_hit & kill_line) == '0)
  `RAPT_SVA_IMPLY(clock, reset, MSHR_STORE_HAS_ROOM, store_fire && store_alloc,
                  free_found && !store_match)
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

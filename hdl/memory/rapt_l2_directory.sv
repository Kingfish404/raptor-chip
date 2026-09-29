// BOOM inclusive-cache directory geometry and one-port access contract.
// Data is stored as one synchronous SRAM per way; a reset wipe clears one
// set in all ways per cycle before requests become ready.
module rapt_l2_directory #(
    parameter int SetBits = 10,
    parameter int Ways = 8,
    parameter int TagBits = 18,
    parameter int ClientBits = 1,
    parameter int WayBits = (Ways <= 1) ? 1 : $clog2(Ways),
    parameter int EntryBits = TagBits + ClientBits + 3
) (
    input logic clock,
    input logic reset,
    output logic ready,
    input logic read_valid,
    output logic read_ready,
    input logic [SetBits-1:0] read_set,
    input logic [TagBits-1:0] read_tag,
    output logic result_valid,
    output logic result_hit,
    output logic [WayBits-1:0] result_way,
    output logic [TagBits-1:0] result_tag,
    output logic [ClientBits-1:0] result_clients,
    output logic [1:0] result_state,
    output logic result_dirty,
    input logic scan_valid,
    output logic scan_ready,
    input logic [SetBits-1:0] scan_set,
    output logic scan_result_valid,
    output logic [Ways*EntryBits-1:0] scan_entries,
    input logic clear_valid,
    output logic clear_ready,
    input logic [SetBits-1:0] clear_set,
    input logic write_valid,
    output logic write_ready,
    input logic [SetBits-1:0] write_set,
    input logic [WayBits-1:0] write_way,
    input logic [TagBits-1:0] write_tag,
    input logic [ClientBits-1:0] write_clients,
    input logic [1:0] write_state,
    input logic write_dirty
);
  localparam logic [1:0] Invalid = 2'b00;

  if (SetBits < 1 || Ways < 1 || Ways > 1024 || (Ways & (Ways - 1)) != 0
      || TagBits < 1 || ClientBits < 1)
    $error("invalid L2 directory geometry");

  logic [SetBits:0] wipe_count;
  logic [SetBits-1:0] wipe_set;
  logic read_fire, scan_fire, clear_fire, write_fire, write_drain;
  logic write_queued;
  logic [SetBits-1:0] queued_set;
  logic [WayBits-1:0] queued_way;
  logic [EntryBits-1:0] queued_entry;
  logic bypass_valid_q;
  logic [WayBits-1:0] bypass_way_q;
  logic [EntryBits-1:0] bypass_entry_q;
  logic scan_bypass_valid_q;
  logic [WayBits-1:0] scan_bypass_way_q;
  logic [EntryBits-1:0] scan_bypass_entry_q;
  logic [TagBits-1:0] read_tag_q;
  logic [WayBits-1:0] victim_way_q;
  logic [15:0] victim_lfsr;
  logic [15:0] next_victim_lfsr;
  logic [EntryBits-1:0] way_data[Ways];
  logic [Ways-1:0] way_hit;
  logic [EntryBits-1:0] selected_entry;

  assign ready = wipe_count[SetBits];
  assign wipe_set = wipe_count[SetBits-1:0];
  // Maintenance clears all ways in one SRAM cycle, as the reset wipe does.
  // Give them priority over new lookups, but first drain any queued write so
  // an older install cannot reappear after its set has been invalidated.
  assign read_ready = ready && !clear_valid && !scan_valid;
  assign scan_ready = ready && !clear_valid;
  assign clear_ready = ready && !write_queued;
  // BOOM's directory places one write in a non-flowing queue. A read may
  // proceed while the queued write waits for the one-port SRAM.
  assign write_ready = ready && !write_queued && !clear_valid;
  assign read_fire = read_valid && read_ready;
  assign scan_fire = scan_valid && scan_ready;
  assign clear_fire = clear_valid && clear_ready;
  assign write_fire = write_valid && write_ready;
  assign write_drain = ready && write_queued && !read_fire && !scan_fire;
  assign next_victim_lfsr = {
    victim_lfsr[14:0],
    victim_lfsr[15] ^ victim_lfsr[13] ^ victim_lfsr[12] ^ victim_lfsr[10]
  };

  for (genvar way = 0; way < Ways; way++) begin : g_way
    logic write_this_way;
    assign write_this_way = write_drain && queued_way == WayBits'(way);
    rapt_sram_1rw #(
        .ADDR_WIDTH(SetBits),
        .DATA_WIDTH(EntryBits),
        .INST_ID(400 + way),
        .USE_BWE(0)
    ) u_directory (
        .clock,
        .en(!ready || clear_fire || read_fire || scan_fire || write_this_way),
        .wen(!ready || clear_fire || write_this_way),
        .addr(!ready ? wipe_set
              : clear_fire ? clear_set
              : read_fire ? read_set : scan_fire ? scan_set : queued_set),
        .rdata(way_data[way]),
        .wdata((!ready || clear_fire) ? '0 : queued_entry),
        .bwe('1)
    );
    assign way_hit[way] = !(bypass_valid_q && bypass_way_q == WayBits'(way))
        && way_data[way][TagBits-1:0] == read_tag_q
        && way_data[way][TagBits+ClientBits+1:TagBits+ClientBits] != Invalid;
    assign scan_entries[way*EntryBits+:EntryBits] =
        scan_bypass_valid_q && scan_bypass_way_q == WayBits'(way)
          ? scan_bypass_entry_q : way_data[way];
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      wipe_count <= '0;
      result_valid <= 1'b0;
      scan_result_valid <= 1'b0;
      read_tag_q <= '0;
      victim_lfsr <= 16'h0001;
      victim_way_q <= '0;
      write_queued <= 1'b0;
      queued_set <= '0;
      queued_way <= '0;
      queued_entry <= '0;
      bypass_valid_q <= 1'b0;
      bypass_way_q <= '0;
      bypass_entry_q <= '0;
      scan_bypass_valid_q <= 1'b0;
      scan_bypass_way_q <= '0;
      scan_bypass_entry_q <= '0;
    end else begin
      if (!ready) wipe_count <= wipe_count + 1'b1;
      result_valid <= read_fire;
      scan_result_valid <= scan_fire;
      if (write_drain) write_queued <= 1'b0;
      if (write_fire) begin
        write_queued <= 1'b1;
        queued_set <= write_set;
        queued_way <= write_way;
        queued_entry <= {write_dirty, write_state, write_clients, write_tag};
      end
      if (read_fire) begin
        read_tag_q <= read_tag;
        victim_lfsr <= next_victim_lfsr;
        victim_way_q <= Ways == 1 ? '0 : WayBits'(next_victim_lfsr[9:0] >> (10 - WayBits));
        // A read sees a write accepted on the same edge as well as a write
        // already waiting in the one-entry queue. Only one can exist.
        bypass_valid_q <= (write_queued && queued_set == read_set)
                          || (write_fire && write_set == read_set);
        bypass_way_q <= write_queued ? queued_way : write_way;
        bypass_entry_q <= write_queued ? queued_entry
                                      : {write_dirty, write_state, write_clients, write_tag};
      end else begin
        bypass_valid_q <= 1'b0;
      end
      if (scan_fire) begin
        scan_bypass_valid_q <= (write_queued && queued_set == scan_set)
                               || (write_fire && write_set == scan_set);
        scan_bypass_way_q <= write_queued ? queued_way : write_way;
        scan_bypass_entry_q <= write_queued ? queued_entry
                                           : {write_dirty, write_state, write_clients, write_tag};
      end else scan_bypass_valid_q <= 1'b0;
    end
  end

  always_comb begin
    result_hit = 1'b0;
    result_way = victim_way_q;
    for (int way = 0; way < Ways; way++) begin
      if (way_hit[way]) begin
        result_hit = 1'b1;
        result_way = WayBits'(way);
      end
    end
    selected_entry = way_data[result_way];
    if (!result_hit && bypass_valid_q) begin
      if (bypass_entry_q[TagBits-1:0] == read_tag_q) begin
        // Even an INVALID write keeps its way as the replacement target.
        // BOOM's scheduler then reuses the way it just invalidated.
        result_hit = bypass_entry_q[TagBits+ClientBits+1:TagBits+ClientBits] != Invalid;
        result_way = bypass_way_q;
        selected_entry = bypass_entry_q;
      end else if (victim_way_q == bypass_way_q) selected_entry = bypass_entry_q;
    end
    {result_dirty, result_state, result_clients, result_tag} = selected_entry;
  end
endmodule

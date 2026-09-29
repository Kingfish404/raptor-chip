// Medium BOOM data geometry: four 16384 x 64 single-port SRAM banks.
// bank=chunk[1:0], row={way[2:0],set[9:0],chunk[2]}.
// Bank priority is SinkC > SourceC > live SinkD > buffered line write
// > SourceD-write > SourceD-read. A displaced buffered beat retries.
module rapt_l2_data_array (
    input logic clock,
    input logic reset,
    input logic read_valid,
    input logic read_all_chunks,
    output logic read_ready,
    input logic [9:0] read_set,
    input logic [2:0] read_way,
    input logic [2:0] read_chunk,
    output logic read_result_valid,
    output logic [511:0] read_line_data,
    input logic source_c_read_valid,
    output logic source_c_read_ready,
    input logic [9:0] source_c_read_set,
    input logic [2:0] source_c_read_way,
    input logic [2:0] source_c_read_chunk,
    output logic source_c_result_valid,
    output logic [63:0] source_c_read_data,
    input logic sink_d_write_valid,
    output logic sink_d_write_ready,
    input logic [9:0] sink_d_write_set,
    input logic [2:0] sink_d_write_way,
    input logic [2:0] sink_d_write_chunk,
    input logic [63:0] sink_d_write_data,
    input logic [7:0] sink_d_write_mask,
    input logic write_line_valid,
    output logic write_line_busy,
    input logic [9:0] write_line_set,
    input logic [2:0] write_line_way,
    input logic [511:0] write_line_data,
    input logic priority_write_valid,
    input logic [9:0] priority_write_set,
    input logic [2:0] priority_write_way,
    input logic [2:0] priority_write_chunk,
    input logic [63:0] priority_write_data,
    input logic [7:0] priority_write_mask,
    input logic write_word_valid,
    output logic write_word_ready,
    input logic [9:0] write_word_set,
    input logic [2:0] write_word_way,
    input logic [2:0] write_word_chunk,
    input logic [63:0] write_word_data,
    input logic [7:0] write_word_mask
);
  logic line_active, read_pending, read_first_pending, read_full_q;
  logic [9:0] line_set_q;
  logic [2:0] line_way_q;
  logic [2:0] line_chunk_q, line_chunk;
  logic [3:0] line_request, line_fire, sink_d_request;
  logic [511:0] line_data_q;
  logic [255:0] read_first_q;
  logic [63:0] bank_rdata[4];
  logic line_issue;
  logic read_no_conflict, scalar_fire, full_start, full_finish;
  logic [13:0] line_row, priority_row, word_row, read_row, source_c_row, sink_d_row;
  logic source_c_fire;
  logic [1:0] source_c_chunk_q;

  assign line_issue = write_line_valid || line_active;
  assign line_chunk = line_active ? line_chunk_q : 3'd0;
  assign line_request = line_issue ? (4'b0001 << line_chunk[1:0]) : 4'h0;
  assign sink_d_request = sink_d_write_valid ? (4'b0001 << sink_d_write_chunk[1:0]) : 4'h0;
  assign write_line_busy = line_active;
  assign line_row = line_active ? {line_way_q, line_set_q, line_chunk_q[2]}
                                : {write_line_way, write_line_set, 1'b0};
  for (genvar bank = 0; bank < 4; bank++) begin : g_line_grant
    assign line_fire[bank] = line_request[bank]
        && !(priority_write_valid && priority_write_chunk[1:0] == 2'(bank))
        && !(source_c_read_valid && source_c_read_chunk[1:0] == 2'(bank))
        && !sink_d_request[bank];
  end
  assign word_row = {write_word_way, write_word_set, write_word_chunk[2]};
  assign priority_row = {priority_write_way, priority_write_set, priority_write_chunk[2]};
  assign read_row = {read_way, read_set, read_all_chunks ? read_pending : read_chunk[2]};
  assign source_c_row = {source_c_read_way, source_c_read_set, source_c_read_chunk[2]};
  assign sink_d_row = {sink_d_write_way, sink_d_write_set, sink_d_write_chunk[2]};
  assign source_c_read_ready = !(priority_write_valid
                                 && priority_write_chunk[1:0] == source_c_read_chunk[1:0]);
  assign source_c_fire = source_c_read_valid && source_c_read_ready;
  assign source_c_read_data = bank_rdata[source_c_chunk_q];
  assign sink_d_write_ready = !(priority_write_valid
                                && priority_write_chunk[1:0] == sink_d_write_chunk[1:0])
      && !(source_c_read_valid && source_c_read_chunk[1:0] == sink_d_write_chunk[1:0]);
  assign write_word_ready = !line_request[write_word_chunk[1:0]]
      && !sink_d_request[write_word_chunk[1:0]]
      && !(source_c_read_valid && source_c_read_chunk[1:0] == write_word_chunk[1:0])
      && !(priority_write_valid
           && priority_write_chunk[1:0] == write_word_chunk[1:0]);
  assign read_no_conflict = !(read_all_chunks && line_issue)
      && !line_request[read_chunk[1:0]]
      && !(sink_d_write_valid && (read_all_chunks
                                  || sink_d_write_chunk[1:0] == read_chunk[1:0]))
      && !(source_c_read_valid && (read_all_chunks
                                   || source_c_read_chunk[1:0] == read_chunk[1:0]))
      && !(priority_write_valid && (read_all_chunks
                                    || priority_write_chunk[1:0] == read_chunk[1:0]))
      && !(write_word_valid && (read_all_chunks
                                || write_word_chunk[1:0] == read_chunk[1:0]));
  // For a line read, ready marks the second row access. The first row is
  // fetched while ready is low and held until the second row can be fetched.
  assign read_ready = read_pending
      ? read_valid && read_all_chunks && read_no_conflict
      : !read_all_chunks && read_no_conflict;
  assign scalar_fire = read_valid && !read_all_chunks && !read_pending && read_ready;
  assign full_start = read_valid && read_all_chunks && !read_pending && read_no_conflict;
  assign full_finish = read_valid && read_all_chunks && read_pending && read_ready;

`ifdef RAPT_ASSERT_EN
  always_ff @(posedge clock) begin
    if (!reset) begin
      assert (!(line_active && write_line_valid))
      else $fatal(1, "BOOM L2 line install overlapped another line install");
    end
  end
`endif

  always_ff @(posedge clock) begin
    if (reset) begin
      line_active <= 1'b0;
      read_pending <= 1'b0;
      read_first_pending <= 1'b0;
      read_result_valid <= 1'b0;
      source_c_result_valid <= 1'b0;
      read_full_q <= 1'b0;
    end else begin
      source_c_result_valid <= source_c_fire;
      if (source_c_fire) source_c_chunk_q <= source_c_read_chunk[1:0];
      if (write_line_valid) begin
        line_set_q   <= write_line_set;
        line_way_q   <= write_line_way;
        line_data_q  <= write_line_data;
        line_active  <= 1'b1;
        line_chunk_q <= line_fire[0] ? 3'd1 : 3'd0;
      end else if (line_active) begin
        if (line_fire[line_chunk_q[1:0]]) begin
          if (line_chunk_q == 3'd7) line_active <= 1'b0;
          else line_chunk_q <= line_chunk_q + 1'b1;
        end
      end
      if (!read_valid) read_pending <= 1'b0;
      else if (full_start) read_pending <= 1'b1;
      else if (full_finish) read_pending <= 1'b0;
      if (read_first_pending) begin
        for (int bank = 0; bank < 4; bank++) read_first_q[bank*64+:64] <= bank_rdata[bank];
        read_first_pending <= 1'b0;
      end
      if (full_start) read_first_pending <= 1'b1;
      read_result_valid <= scalar_fire || full_finish;
      if (scalar_fire) begin
        read_full_q <= 1'b0;
      end else if (full_finish) begin
        read_full_q <= 1'b1;
      end
    end
  end

  for (genvar bank = 0; bank < 4; bank++) begin : g_bank
    logic priority_wen, sink_d_wen, line_wen, word_wen, bank_wen;
    logic [63:0] line_bank_data;
    assign priority_wen = priority_write_valid && priority_write_chunk[1:0] == 2'(bank);
    assign sink_d_wen = sink_d_request[bank] && sink_d_write_ready;
    assign line_wen = line_fire[bank];
    assign word_wen = write_word_valid && write_word_ready && write_word_chunk[1:0] == 2'(bank);
    assign bank_wen = priority_wen || sink_d_wen || line_wen || word_wen;
    assign line_bank_data = line_active
        ? (line_chunk_q[2] ? line_data_q[256+bank*64+:64] : line_data_q[bank*64+:64])
        : write_line_data[bank*64+:64];
    rapt_sram_1rw #(
        .ADDR_WIDTH(14),
        .DATA_WIDTH(64),
        .INST_ID(200 + bank),
        .USE_BWE(1)
    ) u_data_sram (
        .clock,
        .en((full_start || full_finish || scalar_fire && read_chunk[1:0] == 2'(bank))
            || (source_c_fire && source_c_read_chunk[1:0] == 2'(bank)) || bank_wen),
        .wen(bank_wen),
        .addr(bank_wen ? (priority_wen ? priority_row
                          : sink_d_wen ? sink_d_row : line_wen ? line_row : word_row)
              : source_c_fire && source_c_read_chunk[1:0] == 2'(bank) ? source_c_row
              : read_row),
        .rdata(bank_rdata[bank]),
        .wdata(priority_wen ? priority_write_data
               : sink_d_wen ? sink_d_write_data : line_wen ? line_bank_data : write_word_data),
        .bwe(priority_wen ? priority_write_mask
             : sink_d_wen ? sink_d_write_mask : line_wen ? 8'hff : write_word_mask)
    );
  end

  for (genvar chunk = 0; chunk < 8; chunk++) begin : g_read_chunk
    if (chunk < 4) begin : g_first
      assign read_line_data[chunk*64+:64] = read_full_q
          ? read_first_q[chunk*64+:64] : bank_rdata[chunk];
    end else begin : g_second
      assign read_line_data[chunk*64+:64] = bank_rdata[chunk-4];
    end
  end
endmodule

// Indexed 1RW banks serve a fetch window across adjacent sets. The diagonal
// layout shares unused chunk rows across ways without copying data or read ports.
module rapt_l1i_data #(
    parameter int SetBits = 4,
    parameter int WordBits = 2,
    parameter int Ways = 2,
    parameter int Words = 2 ** WordBits,
    parameter int WayBits = Ways > 1 ? $clog2(Ways) : 1
) (
    input logic clock,
    input logic reset,
    input logic [SetBits-1:0] read_set,
    input logic [SetBits-1:0] read_next_set,
    input logic [WordBits-1:0] read_focus_word,
    /* verilator lint_off UNUSEDSIGNAL */
    input logic read_line = 1'b0,
    input logic [WayBits-1:0] read_way = '0,
    /* verilator lint_on UNUSEDSIGNAL */
    input logic write_valid,
    input logic [SetBits-1:0] write_set,
    input logic [WordBits-1:0] write_word,
    input logic [WayBits-1:0] write_way,
    input logic [31:0] write_data,
    output wire [31:0] read_data[Ways][Words],
    output logic [SetBits-1:0] read_index[Ways][Words],
    output logic read_valid[Ways][Words]
);
  if (WordBits >= 3) begin : g_diagonal_banks
    // Four consecutive 64-bit chunks cover the five-word fetch window.
    // Chunk c of way w is in lane c modulo four, bank (w + c/4)
    // modulo Ways, and row {set, c/4}. Unread chunks cannot claim ownership.
    // The fetch window is aligned to a quad; its two low word bits are irrelevant.
    wire unused_focus_word_low = ^read_focus_word[1:0];
    localparam int Lanes = 4;
    localparam int ChunkBits = WordBits - 1;
    localparam int RowBits = WordBits - 3;
    localparam int BankAddrBits = SetBits + RowBits;
    localparam int Groups = Words / 8;
    wire line_read = read_line && Groups <= Ways;
    wire [63:0] bank_rdata[Lanes][Ways];
    logic bank_read_valid[Lanes][Ways];
    logic [ChunkBits-1:0] read_chunk_q[Lanes][Ways];
    logic [SetBits-1:0] read_index_q[Lanes];
    wire [BankAddrBits-1:0] write_row = (BankAddrBits'(write_set) << RowBits)
        | BankAddrBits'(int'(write_word) / 8);

    for (genvar lane = 0; lane < Lanes; lane++) begin : g_lane
      // Align to the old 128-bit group so both halves of its focused quad
      // retain the current set, including the last word of a line.
      wire [1:0] focus_lane = {read_focus_word[2], 1'b0};
      wire [1:0] chunk_delta = 2'(lane) - focus_lane;
      wire [ChunkBits-1:0] window_chunk = {read_focus_word[WordBits-1:2], 1'b0}
          + ChunkBits'(chunk_delta);
      wire focused = window_chunk[ChunkBits-1:1] == read_focus_word[WordBits-1:2];
      wire [SetBits-1:0] bank_read_addr = line_read || focused ? read_set : read_next_set;
      always_ff @(posedge clock) read_index_q[lane] <= bank_read_addr;
      for (genvar bank = 0; bank < Ways; bank++) begin : g_bank
        wire [WayBits-1:0] bank_delta = WayBits'(bank) - read_way;
        wire [ChunkBits-1:0] read_chunk = line_read && int'(bank_delta) < Groups
            ? ChunkBits'(lane + int'(bank_delta) * Lanes) : window_chunk;
        wire [BankAddrBits-1:0] read_row = (BankAddrBits'(bank_read_addr) << RowBits)
            | BankAddrBits'(int'(read_chunk) / Lanes);
        always_ff @(posedge clock) read_chunk_q[lane][bank] <= read_chunk;
        wire write_bank = write_valid && int'(write_way) < Ways
            && write_word[2:1] == 2'(lane)
            && (int'(write_way) + int'(write_word) / 8) % Ways == bank;
        rapt_sram_1rw #(
            .ADDR_WIDTH(BankAddrBits),
            .DATA_WIDTH(64),
            .USE_BWE(1'b1)
        ) u_sram (
            .clock(clock),
            .en(1'b1),
            .wen(write_bank),
            .addr(write_bank ? write_row : read_row),
            .rdata(bank_rdata[lane][bank]),
            .wdata({2{write_data}}),
            .bwe(write_word[0] ? 8'hf0 : 8'h0f)
        );
        always_ff @(posedge clock) bank_read_valid[lane][bank] <= !reset && !write_bank;
      end
    end
    for (genvar way = 0; way < Ways; way++) begin : g_way
      for (genvar word_idx = 0; word_idx < Words; word_idx++) begin : g_word
        localparam int Lane = (word_idx / 2) % Lanes;
        localparam int Bank = (way + word_idx / 8) % Ways;
        assign read_data[way][word_idx] = bank_rdata[Lane][Bank][(word_idx%2)*32+:32];
        assign read_index[way][word_idx] = read_index_q[Lane];
        assign read_valid[way][word_idx] = bank_read_valid[Lane][Bank]
            && read_chunk_q[Lane][Bank] == ChunkBits'(word_idx / 2);
      end
    end
  end else begin : g_word_banks
    // Small-line presets keep independently addressed words, including the
    // 16-byte line whose first and last words would share one quad bank.
    logic [SetBits-1:0] read_index_q[Words];
    wire [SetBits-1:0] word_read_addr[Words];
    for (genvar word_idx = 0; word_idx < Words; word_idx++) begin : g_read_index
      assign word_read_addr[word_idx] = read_focus_word == WordBits'(word_idx)
          ? read_set : read_next_set;
      always_ff @(posedge clock) read_index_q[word_idx] <= word_read_addr[word_idx];
    end
    for (genvar way = 0; way < Ways; way++) begin : g_way
      for (genvar word_idx = 0; word_idx < Words; word_idx++) begin : g_word
        wire write_bank = write_valid && write_way == WayBits'(way)
                          && write_word == WordBits'(word_idx);
        assign read_index[way][word_idx] = read_index_q[word_idx];
        rapt_sram_1rw #(
            .ADDR_WIDTH(SetBits),
            .DATA_WIDTH(32)
        ) u_sram (
            .clock(clock),
            .en(1'b1),
            .wen(write_bank),
            .addr(write_bank ? write_set : word_read_addr[word_idx]),
            .rdata(read_data[way][word_idx]),
            .wdata(write_data),
            .bwe('0)
        );
        always_ff @(posedge clock) read_valid[way][word_idx] <= !reset && !write_bank;
      end
    end
  end
endmodule

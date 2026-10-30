`include "rapt.svh"

// Chunk c of way w is in bank (w + c) modulo Chunks, within w's group.
// A word read visits chunk c in every bank; a line read visits all chunks
// of one way. Partial groups compact the row to c modulo GroupWays, so
// four-way caches use 256x64 banks without allocating unreachable rows.
module rapt_l1d_data #(
    parameter int Xlen = 32,
    parameter int SetBits = 4,
    parameter int WordBits = 2,
    parameter int Ways = 2,
    parameter int LineWords = 2 ** WordBits,
    parameter int WayBits = Ways > 1 ? $clog2(Ways) : 1,
    parameter int Chunks = LineWords * Xlen / 64,
    parameter int Banks = ((Ways + Chunks - 1) / Chunks) * Chunks
) (
    input logic clock,
    input logic reset,
    input logic [SetBits-1:0] read_addr,
    input logic [WordBits-1:0] read_word,
    input logic read_line,
    input logic [WayBits-1:0] read_way,
    input logic write_valid,
    input logic write_blocked = 1'b0,
    input logic [SetBits-1:0] write_addr,
    input logic [WordBits-1:0] write_word,
    input logic [WayBits-1:0] write_way,
    input logic [Xlen-1:0] write_data,
    input logic [Xlen/8-1:0] write_strobe = '1,
    input logic write_line = 1'b0,
    input logic [LineWords-1:0] write_mask = '0,
    input logic [LineWords*Xlen-1:0] write_line_data = '0,
    output logic [SetBits-1:0] read_index,
    output logic [WordBits-1:0] read_word_index,
    output wire [Banks-1:0] read_bank_valid,
    output wire [63:0] read_data[Banks],
    output logic read_line_valid,
    output wire [LineWords*Xlen-1:0] read_line_data
);
  localparam int WordBytes = Xlen / 8;
  localparam int ChunkWords = 64 / Xlen;
  localparam int GroupWays = Ways < Chunks ? Ways : Chunks;
  localparam int RowBits = $clog2(GroupWays);
  localparam int BankAddrBits = SetBits + RowBits;
  localparam int ChunkBits = Chunks > 1 ? $clog2(Chunks) : 1;
  logic [WayBits-1:0] line_way_q;
  logic line_read_q;

  if (!((Xlen == 32 || Xlen == 64) && SetBits > 0 && WordBits > 0
        && Ways > 0 && (Ways & (Ways - 1)) == 0 && LineWords == 2 ** WordBits
        && LineWords * Xlen >= 64
        && WayBits == (Ways > 1 ? $clog2(
          Ways
      ) : 1))) begin : g_invalid_config
    $error("Invalid rapt_l1d_data configuration");
  end

  always_ff @(posedge clock) begin
    read_index <= read_addr;
    read_word_index <= read_word;
    line_way_q <= read_way;
    line_read_q <= !reset && read_line;
  end

  for (genvar bank = 0; bank < Banks; bank++) begin : g_bank
    localparam int Group = bank / Chunks;
    localparam int Lane  = bank % Chunks;
    wire [ChunkBits-1:0] write_chunk = ChunkBits'(Lane - int'(write_way) % Chunks);
    wire [ChunkBits-1:0] read_chunk = read_line
        ? ChunkBits'(Lane - int'(read_way) % Chunks) : ChunkBits'(int'(read_word) / ChunkWords);
    wire [BankAddrBits-1:0] read_row = (BankAddrBits'(read_addr) << RowBits)
        | BankAddrBits'(int'(read_chunk) % GroupWays);
    wire [BankAddrBits-1:0] write_row = (BankAddrBits'(write_addr) << RowBits)
        | BankAddrBits'(int'(write_chunk) % GroupWays);
    wire [7:0] byte_enable;
    wire [63:0] bank_wdata;
    wire bank_write = |byte_enable;
    logic bank_read_valid;

    for (genvar word_idx = 0; word_idx < ChunkWords; word_idx++) begin : g_word
      wire [WordBits-1:0] word_offset = WordBits'(int'(write_chunk) * ChunkWords + word_idx);
      assign byte_enable[word_idx*WordBytes+:WordBytes] =
          {WordBytes{write_valid && int'(write_way) / Chunks == Group
                     && (write_line ? write_mask[word_offset] : write_word == word_offset)}}
          & (write_line ? {WordBytes{1'b1}} : write_strobe);
      assign bank_wdata[word_idx*Xlen+:Xlen] = write_line
          ? write_line_data[word_offset*Xlen+:Xlen] : write_data;
    end

    always_ff @(posedge clock) begin
      if (reset || bank_write) bank_read_valid <= 1'b0;
      else bank_read_valid <= 1'b1;
    end
    assign read_bank_valid[bank] = bank_read_valid;

    // Registered write metadata reserves the address even if a late dirty
    // conflict suppresses the access. Arbitration reaches only en/wen.
    rapt_sram_1rw #(
        .ADDR_WIDTH(BankAddrBits),
        .DATA_WIDTH(64),
        .USE_BWE(1)
    ) u_sram (
        .clock(clock),
        .en(!bank_write || !write_blocked),
        .wen(bank_write && !write_blocked),
        .addr(bank_write ? write_row : read_row),
        .rdata(read_data[bank]),
        .wdata(bank_wdata),
        .bwe(byte_enable)
    );
  end

  always_comb begin
    read_line_valid = line_read_q;
    for (int chunk = 0; chunk < Chunks; chunk++) begin
      read_line_valid &= read_bank_valid[(int'(line_way_q) / Chunks) * Chunks
          + ((int'(line_way_q) + chunk) % Chunks)];
    end
  end
  for (genvar chunk = 0; chunk < Chunks; chunk++) begin : g_line_data
    wire [63:0] chunk_data = read_data[(int'(line_way_q) / Chunks) * Chunks
        + ((int'(line_way_q) + chunk) % Chunks)];
    assign read_line_data[chunk*64+:64] = chunk_data;
  end
endmodule

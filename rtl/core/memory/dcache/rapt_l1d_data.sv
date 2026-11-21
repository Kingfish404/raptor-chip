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
    input rapt_pkg::sram_ctrl_t sram_ctrl_i,
    input logic clock,
    input logic reset,
    input logic [SetBits-1:0] read_addr,
    input logic [WordBits-1:0] read_word,
    input logic read_line,
    input logic [WayBits-1:0] read_way,
    input logic write_valid,
    input logic write_blocked,
    input logic [SetBits-1:0] write_addr,
    input logic [WordBits-1:0] write_word,
    input logic [WayBits-1:0] write_way,
    input logic [Xlen-1:0] write_data,
    input logic [Xlen/8-1:0] write_strobe,
    input logic write_line,
    input logic [LineWords-1:0] write_mask,
    input logic [LineWords*Xlen-1:0] write_line_data,
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
  localparam int NumGroups = Banks / Chunks;
  localparam int GroupBits = NumGroups > 1 ? $clog2(NumGroups) : 1;

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

  // Hoist per-lane row, write-data and byte-strobe muxing across groups so
  // synthesis builds Chunks copies rather than Banks copies for high-way L1Ds.
  logic [BankAddrBits-1:0] lane_read_row[Chunks];
  logic [BankAddrBits-1:0] lane_write_row[Chunks];
  logic [63:0] lane_wdata[Chunks];
  logic [7:0] lane_strobe[Chunks];
  for (genvar lane = 0; lane < Chunks; lane++) begin : g_lane_prep
    wire [ChunkBits-1:0] write_chunk = ChunkBits'(lane - int'(write_way) % Chunks);
    wire [ChunkBits-1:0] read_chunk = read_line
        ? ChunkBits'(lane - int'(read_way) % Chunks) : ChunkBits'(int'(read_word) / ChunkWords);
    assign lane_read_row[lane] = (BankAddrBits'(read_addr) << RowBits)
        | BankAddrBits'(int'(read_chunk) % GroupWays);
    assign lane_write_row[lane] = (BankAddrBits'(write_addr) << RowBits)
        | BankAddrBits'(int'(write_chunk) % GroupWays);
    for (genvar word_idx = 0; word_idx < ChunkWords; word_idx++) begin : g_word
      wire [WordBits-1:0] word_offset = WordBits'(int'(write_chunk) * ChunkWords + word_idx);
      wire word_hit = write_line ? write_mask[word_offset] : (write_word == word_offset);
      assign lane_strobe[lane][word_idx*WordBytes+:WordBytes] =
          {WordBytes{word_hit}} & (write_line ? {WordBytes{1'b1}} : write_strobe);
      assign lane_wdata[lane][word_idx*Xlen+:Xlen] = write_line
          ? write_line_data[word_offset*Xlen+:Xlen] : write_data;
    end
  end

  for (genvar bank = 0; bank < Banks; bank++) begin : g_bank
    localparam int Group = bank / Chunks;
    localparam int Lane  = bank % Chunks;
    wire group_write = write_valid && (int'(write_way) / Chunks == Group);
    wire [7:0] byte_enable = group_write ? lane_strobe[Lane] : 8'd0;
    wire bank_write = |byte_enable;
    logic bank_read_valid;

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
        .sram_ctrl_i(sram_ctrl_i),
        .clock(clock),
        .en(!bank_write || !write_blocked),
        .wen(bank_write && !write_blocked),
        .addr(bank_write ? lane_write_row[Lane] : lane_read_row[Lane]),
        .rdata(read_data[bank]),
        .wdata(lane_wdata[Lane]),
        .bwe(byte_enable)
    );
  end

  // Two-stage line readback: select the active group per lane first, then
  // rotate across Chunks lanes. This replaces Chunks x Banks:1 muxes with
  // Chunks x NumGroups:1 + Chunks x Chunks:1 muxes.
  logic [63:0] lane_line_data[Chunks];
  logic [Chunks-1:0] lane_line_valid;
  for (genvar lane = 0; lane < Chunks; lane++) begin : g_line_group
    if (NumGroups == 1) begin : g_single_group
      assign lane_line_data[lane] = read_data[lane];
      assign lane_line_valid[lane] = read_bank_valid[lane];
    end else begin : g_multi_group
      wire [GroupBits-1:0] line_group = GroupBits'(int'(line_way_q) / Chunks);
      assign lane_line_data[lane] = read_data[int'(line_group) * Chunks + lane];
      assign lane_line_valid[lane] = read_bank_valid[int'(line_group) * Chunks + lane];
    end
  end

  assign read_line_valid = line_read_q && (&lane_line_valid);
  for (genvar chunk = 0; chunk < Chunks; chunk++) begin : g_line_data
    wire [ChunkBits-1:0] rot_lane = ChunkBits'((int'(line_way_q) + chunk) % Chunks);
    assign read_line_data[chunk*64+:64] = lane_line_data[rot_lane];
  end
endmodule

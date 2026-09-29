`include "rapt.svh"
// L1D word-write / line-read data array, built from <=128-bit 1RW SRAMs.
// A write reserves only its selected way/subarray. Other banks read on the
// same edge; each bank reports which set its output currently represents.
module rapt_l1d_data #(
    parameter int Xlen = 32,
    parameter int SetBits = 4,
    parameter int WordBits = 2,
    parameter int Ways = 2,
    parameter int LineWords = 2 ** WordBits,
    parameter int WayBits = Ways > 1 ? $clog2(Ways) : 1
) (
    input logic clock,
    input logic reset,
    input logic [SetBits-1:0] read_addr,
    input logic write_valid,
    input logic [SetBits-1:0] write_addr,
    input logic [WordBits-1:0] write_word,
    input logic [WayBits-1:0] write_way,
    input logic [Xlen-1:0] write_data,
    input logic [Xlen/8-1:0] write_strobe = '1,
    input logic write_line = 1'b0,
    input logic [LineWords-1:0] write_mask = '0,
    input logic [LineWords*Xlen-1:0] write_line_data = '0,
    output logic read_valid,
    output logic [SetBits-1:0] read_index,
    output wire [Ways-1:0][LineWords-1:0] read_word_valid,
    output wire [SetBits-1:0] read_word_index[Ways][LineWords],
    output wire [Xlen-1:0] read_data[Ways][LineWords]
);
  localparam int WordBytes = Xlen / 8;
  localparam int MaxSubarrayWords = `RAPT_CACHE_SRAMLEN / Xlen;
  localparam int SubarrayWords = LineWords < MaxSubarrayWords ? LineWords : MaxSubarrayWords;
  localparam int SubarrayBytes = SubarrayWords * WordBytes;
  localparam int Subarrays = LineWords / SubarrayWords;

  if (!((Xlen == 32 || Xlen == 64) && SetBits > 0 && WordBits > 0
        && Ways > 0 && LineWords == 2 ** WordBits
        && WayBits == (Ways > 1 ? $clog2(
          Ways
      ) : 1))) begin : g_invalid_config
    $error("Invalid rapt_l1d_data configuration");
  end

  // Preserve the all-bank contract for clients that require a complete line.
  always_ff @(posedge clock) begin
    if (reset) begin
      read_valid <= 1'b0;
    end else begin
      read_valid <= !write_valid;
    end
    // All banks that do read in this cycle use the same address. Reuse this
    // register for their index instead of storing an index in every bank.
    if (!reset) read_index <= read_addr;
  end

  for (genvar way = 0; way < Ways; way++) begin : g_way
    for (genvar bank = 0; bank < Subarrays; bank++) begin : g_bank
      localparam int BaseWord = bank * SubarrayWords;
      wire [SubarrayBytes-1:0] byte_enable;
      wire [SubarrayBytes*8-1:0] bank_data, bank_wdata;
      wire  bank_write = |byte_enable;
      logic bank_read_valid;

      always_ff @(posedge clock) begin
        if (reset || bank_write) bank_read_valid <= 1'b0;
        else bank_read_valid <= 1'b1;
      end

      // Each generated word owns its byte-enable and read-data slice.
      // Replication distributes the same full-word payload to every lane.
      for (genvar word_idx = 0; word_idx < SubarrayWords; word_idx++) begin : g_word
        assign byte_enable[word_idx*WordBytes+:WordBytes] =
            {WordBytes{write_valid && write_way == WayBits'(way)
                       && (write_line ? write_mask[BaseWord+word_idx]
                   : write_word == WordBits'(BaseWord + word_idx))}}
          & (write_line ? {WordBytes{1'b1}} : write_strobe);
        assign bank_wdata[word_idx*Xlen+:Xlen] = write_line
            ? write_line_data[(BaseWord+word_idx)*Xlen+:Xlen] : write_data;
        assign read_word_valid[way][BaseWord+word_idx] = bank_read_valid;
        assign read_word_index[way][BaseWord+word_idx] = read_index;
        assign read_data[way][BaseWord+word_idx] = bank_data[word_idx*Xlen+:Xlen];
      end

      rapt_sram_1rw #(
          .ADDR_WIDTH(SetBits),
          .DATA_WIDTH(SubarrayBytes * 8),
          .USE_BWE(1)
      ) u_sram (
          .clock(clock),
          .en(1'b1),
          .wen(bank_write),
          .addr(bank_write ? write_addr : read_addr),
          .rdata(bank_data),
          .wdata(bank_wdata),
          .bwe(byte_enable)
      );
    end
  end
endmodule

// L1D word-write / line-read data array, built from <=128-bit 1RW SRAMs.
// A write reserves the entire array's port for the cycle, even though only
// one way/subarray is enabled. Read data is usable only when read_valid is
// set and read_index matches the consumer's requested set.
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
    output logic read_valid,
    output logic [SetBits-1:0] read_index,
    output wire [Xlen-1:0] read_data[Ways][LineWords]
);
  localparam int WordBytes = Xlen / 8;
  localparam int MaxSubarrayWords = 128 / Xlen;
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

  // SRAM writes/disabled banks may hold different old read addresses.
  // Only an all-bank read establishes a common, consumable index again.
  always_ff @(posedge clock) begin
    if (reset) begin
      read_valid <= 1'b0;
    end else if (write_valid) begin
      read_valid <= 1'b0;
    end else begin
      read_valid <= 1'b1;
      read_index <= read_addr;
    end
  end

  for (genvar way = 0; way < Ways; way++) begin : g_way
    for (genvar bank = 0; bank < Subarrays; bank++) begin : g_bank
      localparam int BaseWord = bank * SubarrayWords;
      wire [SubarrayBytes-1:0] byte_enable;
      wire [SubarrayBytes*8-1:0] bank_data;
      wire bank_write = |byte_enable;

      // Each generated word owns its byte-enable and read-data slice.
      // Replication distributes the same full-word payload to every lane.
      for (genvar word_idx = 0; word_idx < SubarrayWords; word_idx++) begin : g_word
        assign byte_enable[word_idx*WordBytes+:WordBytes] =
            {WordBytes{write_valid && write_way == WayBits'(way)
                       && write_word == WordBits'(BaseWord + word_idx)}};
        assign read_data[way][BaseWord+word_idx] = bank_data[word_idx*Xlen+:Xlen];
      end

      rapt_sram_1rw #(
          .ADDR_WIDTH(SetBits),
          .DATA_WIDTH(SubarrayBytes * 8),
          .USE_BWE(1)
      ) u_sram (
          .clock(clock),
          .en(bank_write || !write_valid),
          .wen(bank_write),
          .addr(bank_write ? write_addr : read_addr),
          .rdata(bank_data),
          .wdata({SubarrayWords{write_data}}),
          .bwe(byte_enable)
      );
    end
  end
endmodule

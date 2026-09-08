// Independent word banks let a fetch window straddle adjacent cache sets.
// Every bank owns its accepted-read address/validity beside the 1RW SRAM.
module rapt_l1i_data #(
    parameter int SetBits = 4,
    parameter int WordBits = 2,
    parameter int Ways = 2,
    parameter int Words = 2 ** WordBits,
    parameter int WayBits = Ways > 1 ? $clog2(Ways) : 1
) (
    input logic clock,
    input logic reset,
    input logic [SetBits-1:0] read_addr[Words],
    input logic write_valid,
    input logic [SetBits-1:0] write_set,
    input logic [WordBits-1:0] write_word,
    input logic [WayBits-1:0] write_way,
    input logic [31:0] write_data,
    output wire [31:0] read_data[Ways][Words],
    output logic [SetBits-1:0] read_index[Ways][Words],
    output logic read_valid[Ways][Words]
);
  for (genvar way = 0; way < Ways; way++) begin : g_way
    for (genvar word_idx = 0; word_idx < Words; word_idx++) begin : g_word
      wire write_bank = write_valid && write_way == WayBits'(way)
                        && write_word == WordBits'(word_idx);
      rapt_sram_1rw #(
          .ADDR_WIDTH(SetBits),
          .DATA_WIDTH(32)
      ) u_sram (
          .clock(clock),
          .en(1'b1),
          .wen(write_bank),
          .addr(write_bank ? write_set : read_addr[word_idx]),
          .rdata(read_data[way][word_idx]),
          .wdata(write_data),
          .bwe('0)
      );
      always_ff @(posedge clock) begin
        if (reset || write_bank) read_valid[way][word_idx] <= 1'b0;
        else begin
          read_index[way][word_idx] <= read_addr[word_idx];
          read_valid[way][word_idx] <= 1'b1;
        end
      end
    end
  end
endmodule

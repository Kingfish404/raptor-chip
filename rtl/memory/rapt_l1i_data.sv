// Independently addressed banks let a fetch window straddle adjacent sets.
// Ways share each bank's read address; each way owns its read validity.
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
    input logic [WordBits-1:0] read_focus_word,
    input logic write_valid,
    input logic [SetBits-1:0] write_set,
    input logic [WordBits-1:0] write_word,
    input logic [WayBits-1:0] write_way,
    input logic [31:0] write_data,
    output wire [31:0] read_data[Ways][Words],
    output logic [SetBits-1:0] read_index[Ways][Words],
    output logic read_valid[Ways][Words]
);
  if (WordBits >= 3) begin : g_quad_banks
    // A 64-byte line has four independently addressed 128-bit banks per way.
    // The focused word's set wins within its bank; the other banks pre-read
    // the next line. The word at a line boundary is in a different bank from
    // the first word of the next line, preserving the cross-line fetch port.
    localparam int Banks = Words / 4;
    for (genvar bank = 0; bank < Banks; bank++) begin : g_bank
      logic [SetBits-1:0] bank_read_addr, read_index_q;
      wire focused = read_focus_word[WordBits-1:2] == (WordBits - 2)'(bank);
      assign bank_read_addr = focused ? read_addr[read_focus_word] : read_addr[bank*4];
      always_ff @(posedge clock) read_index_q <= bank_read_addr;
      for (genvar way = 0; way < Ways; way++) begin : g_way
        wire write_bank = write_valid && write_way == WayBits'(way)
                          && write_word[WordBits-1:2] == (WordBits-2)'(bank);
        wire [3:0] write_bytes = 4'b0001 << write_word[1:0];
        wire [127:0] bank_rdata;
        rapt_sram_1rw #(
            .ADDR_WIDTH(SetBits),
            .DATA_WIDTH(128),
            .USE_BWE(1'b1)
        ) u_sram (
            .clock(clock),
            .en(1'b1),
            .wen(write_bank),
            .addr(write_bank ? write_set : bank_read_addr),
            .rdata(bank_rdata),
            .wdata({4{write_data}}),
            .bwe({{4{write_bytes[3]}}, {4{write_bytes[2]}},
                  {4{write_bytes[1]}}, {4{write_bytes[0]}}})
        );
        for (genvar lane = 0; lane < 4; lane++) begin : g_lane
          assign read_data[way][bank*4+lane] = bank_rdata[lane*32+:32];
          assign read_index[way][bank*4+lane] = read_index_q;
          always_ff @(posedge clock) begin
            read_valid[way][bank*4+lane] <= !reset && !write_bank;
          end
        end
      end
    end
  end else begin : g_word_banks
    // Small-line presets keep independently addressed words, including the
    // 16-byte line whose first and last words would share one quad bank.
    logic [SetBits-1:0] read_index_q[Words];
    for (genvar word_idx = 0; word_idx < Words; word_idx++) begin : g_read_index
      always_ff @(posedge clock) read_index_q[word_idx] <= read_addr[word_idx];
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
            .addr(write_bank ? write_set : read_addr[word_idx]),
            .rdata(read_data[way][word_idx]),
            .wdata(write_data),
            .bwe('0)
        );
        always_ff @(posedge clock) read_valid[way][word_idx] <= !reset && !write_bank;
      end
    end
  end
endmodule

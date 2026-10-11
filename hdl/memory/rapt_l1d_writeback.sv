`include "rapt.svh"

module rapt_l1d_writeback #(
    parameter int Xlen = `RAPT_XLEN,
    parameter int LineWords = 16,
    parameter int WordBits = $clog2(LineWords),
    parameter int Entries = 1,
    parameter bit AllowRetry = 1'b0
) (
    input logic clock,
    input logic reset,
    input logic capture_valid,
    output logic capture_ready,
    input logic [Xlen-1:0] capture_addr,
    input logic [LineWords-1:0] capture_dirty,
    input logic [LineWords*Xlen-1:0] capture_data,
    output logic busy,
    output logic error,
    input logic retry,
    output logic write_valid,
    output logic [Xlen-1:0] write_addr,
    output logic [Xlen-1:0] write_data,
    input logic write_ready,
    input logic write_error,
    // Physical line hazards: never read old memory behind a pending writeback.
    input logic [Xlen-1:0] read_addr,
    input logic [Xlen-1:0] miss_addr,
    output logic read_match,
    output logic miss_match
);
  localparam int ByteBits = $clog2(Xlen / 8);
  localparam int LineBits = WordBits + ByteBits;
  localparam int PtrBits  = Entries > 1 ? $clog2(Entries) : 1;
  logic [PtrBits-1:0] head, tail;
  logic [$clog2(Entries+1)-1:0] count;
  // FIFO order preserves stores to the same physical line across evictions.
  logic [Xlen-1:LineBits] line_addr_q[Entries];
  logic [LineWords-1:0] dirty[Entries];
  logic [LineWords*Xlen-1:0] data[Entries];
  logic [WordBits-1:0] word_index;
  logic push, pop;

  if (Entries < 1 || Entries > 2 || !(Xlen inside {32, 64}) || LineWords < 2
      || (LineWords & (LineWords - 1)) != 0 || WordBits != $clog2(
          LineWords
      )) begin : g_invalid
    $error("Invalid L1D writeback geometry");
  end

  always_comb begin
    word_index = '0;
    for (int word_idx = LineWords - 1; word_idx >= 0; word_idx--)
    if (dirty[head][word_idx]) word_index = WordBits'(word_idx);
    read_match = 0;
    miss_match = 0;
    for (int i = 0; i < Entries; i++) begin
      read_match |= (|dirty[i]) && line_addr_q[i] == read_addr[Xlen-1:LineBits];
      miss_match |= (|dirty[i]) && line_addr_q[i] == miss_addr[Xlen-1:LineBits];
    end
  end

  assign busy = count != 0;
  assign capture_ready = int'(count) < Entries && !error;
  assign write_valid = busy && !error;
  assign write_addr = {line_addr_q[head], word_index, {ByteBits{1'b0}}};
  assign write_data = data[head][word_index*Xlen+:Xlen];
  assign push = capture_valid && capture_ready && |capture_dirty;
  assign pop = write_valid && write_ready && !write_error
      && dirty[head] == (LineWords'(1) << word_index);

  always_ff @(posedge clock) begin
    if (reset) begin
      for (int i = 0; i < Entries; i++) dirty[i] <= '0;
      head <= '0;
      tail <= '0;
      count <= '0;
      error <= 1'b0;
    end else begin
      case ({
        push, pop
      })
        2'b10: count <= count + 1'b1;
        2'b01: count <= count - 1'b1;
        default: ;
      endcase
      if (push) begin
        line_addr_q[tail] <= capture_addr[Xlen-1:LineBits];
        dirty[tail] <= capture_dirty;
        data[tail] <= capture_data;
        tail <= int'(tail) == Entries-1 ? '0 : tail + 1'b1;
      end
      if (write_valid && write_ready) begin
        if (write_error) error <= 1'b1;
        else begin
          dirty[head][word_index] <= 1'b0;
          if (pop) head <= int'(head) == Entries - 1 ? '0 : head + 1'b1;
        end
      end else if (AllowRetry && error && retry) error <= 1'b0;
    end
  end
endmodule

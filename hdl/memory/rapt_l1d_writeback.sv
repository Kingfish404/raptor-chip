`include "rapt.svh"

module rapt_l1d_writeback #(
    parameter int Xlen = `RAPT_XLEN,
    parameter int LineWords = 16,
    parameter int WordBits = $clog2(LineWords),
    parameter int Entries = 1,
    parameter bit Pipelined = 1'b0,
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
    input logic write_accept = 1'b0,
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
  logic [LineWords-1:0] issued[Entries];
  logic [LineWords*Xlen-1:0] data[Entries];
  logic [WordBits-1:0] word_index, retire_word;
  logic [PtrBits-1:0] issue_entry;
  logic issue_valid;
  logic push, pop;

  if (Entries < 1 || Entries > 2 || !(Xlen inside {32, 64}) || LineWords < 2
      || (LineWords & (LineWords - 1)) != 0 || WordBits != $clog2(
          LineWords
      )) begin : g_invalid
    $error("Invalid L1D writeback geometry");
  end

  if (Pipelined && AllowRetry) begin : g_invalid_retry
    $error("Pipelined writebacks require fail-stop error handling");
  end

  always_comb begin
    // Requests issue in FIFO/word order; dirty bits remain owned until B.
    // Separate issued bits let younger words/entries use the downstream
    // credits without losing either payload or same-line read hazards.
    retire_word = '0;
    for (int word_idx = LineWords - 1; word_idx >= 0; word_idx--)
    if (dirty[head][word_idx]) retire_word = WordBits'(word_idx);
    issue_entry = head;
    word_index = retire_word;
    issue_valid = |dirty[head];
    if (Pipelined) begin
      issue_valid = 0;
      for (int offset_idx = Entries - 1; offset_idx >= 0; offset_idx--) begin
        for (int word_idx = LineWords - 1; word_idx >= 0; word_idx--) begin
          if (dirty[(int'(head)+offset_idx)%Entries][word_idx]
              && !issued[(int'(head)+offset_idx)%Entries][word_idx]) begin
            issue_entry = PtrBits'((int'(head)+offset_idx)%Entries);
            word_index = WordBits'(word_idx);
            issue_valid = 1;
          end
        end
      end
    end
    if (error) begin
      issue_entry = head;
      word_index = retire_word;
    end
    read_match = 0;
    miss_match = 0;
    for (int i = 0; i < Entries; i++) begin
      read_match |= (|dirty[i]) && line_addr_q[i] == read_addr[Xlen-1:LineBits];
      miss_match |= (|dirty[i]) && line_addr_q[i] == miss_addr[Xlen-1:LineBits];
    end
  end

  assign busy = count != 0;
  assign capture_ready = int'(count) < Entries && !error;
  assign write_valid = busy && issue_valid && !error;
  assign write_addr = {line_addr_q[issue_entry], word_index, {ByteBits{1'b0}}};
  assign write_data = data[issue_entry][word_index*Xlen+:Xlen];
  assign push = capture_valid && capture_ready && |capture_dirty;
  assign pop = busy && !error && write_ready && !write_error
      && dirty[head] == (LineWords'(1) << retire_word);

  always_ff @(posedge clock) begin
    if (reset) begin
      for (int i = 0; i < Entries; i++) begin
        dirty[i] <= '0;
        issued[i] <= '0;
      end
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
        issued[tail] <= '0;
        data[tail] <= capture_data;
        tail <= int'(tail) == Entries-1 ? '0 : tail + 1'b1;
      end
      if (Pipelined && write_valid && write_accept) issued[issue_entry][word_index] <= 1'b1;
      if (busy && !error && write_ready) begin
        if (write_error) error <= 1'b1;
        else begin
          dirty[head][retire_word] <= 1'b0;
          if (pop) head <= int'(head) == Entries - 1 ? '0 : head + 1'b1;
        end
      end else if (AllowRetry && error && retry && !Pipelined) error <= 1'b0;
    end
  end
endmodule

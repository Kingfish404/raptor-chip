`include "rapt.svh"

module rapt_l1d_writeback #(
    parameter int Xlen = `RAPT_XLEN,
    parameter int LineWords = 16,
    parameter int WordBits = $clog2(LineWords),
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
    input logic write_error
);
  localparam int ByteBits = $clog2(Xlen / 8);
  localparam int LineBits = WordBits + ByteBits;
  logic [Xlen-1:0] line_addr;
  logic [LineWords-1:0] dirty;
  logic [LineWords*Xlen-1:0] data;
  logic [WordBits-1:0] word_index;

  if (!(Xlen inside {32, 64}) || LineWords < 2
      || (LineWords & (LineWords - 1)) != 0 || WordBits != $clog2(
          LineWords
      )) begin : g_invalid
    $error("Invalid L1D writeback geometry");
  end

  always_comb begin
    word_index = '0;
    for (int word_idx = LineWords - 1; word_idx >= 0; word_idx--)
    if (dirty[word_idx]) word_index = WordBits'(word_idx);
  end

  assign busy = |dirty;
  assign capture_ready = !busy;
  assign write_valid = busy && !error;
  assign write_addr = line_addr | (Xlen'(word_index) << ByteBits);
  assign write_data = data[word_index*Xlen+:Xlen];

  always_ff @(posedge clock) begin
    if (reset) begin
      dirty <= '0;
      error <= 1'b0;
    end else begin
      if (capture_valid && capture_ready) begin
        line_addr <= {capture_addr[Xlen-1:LineBits], {LineBits{1'b0}}};
        dirty <= capture_dirty;
        data <= capture_data;
        error <= 1'b0;
      end else if (write_valid && write_ready) begin
        if (write_error) error <= 1'b1;
        else dirty[word_index] <= 1'b0;
      end else if (AllowRetry && error && retry) begin
        error <= 1'b0;
      end
    end
  end
endmodule

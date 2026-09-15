// Symmetric overlap of short, circular word ranges. Each access spans at most
// four words. Split each word index into a two-bit offset and an upper chunk.
// A short range can cross at most one chunk boundary; share that successor
// across comparisons instead of building full-width successors for each offset.
module rapt_ioq_overlap #(
    parameter int Xlen = 32,
    parameter int Entries = 8,
    parameter int WordOffBits = 2,
    parameter int PageOffBits = 12
) (
    input logic [Xlen-1:0] addr[Entries],
    input logic [1:0] span[Entries],
    input logic page_only,
    output logic [Entries-1:0] overlap[Entries]
);
  localparam int WordBits = Xlen - WordOffBits;
  localparam int PageWordBits = PageOffBits - WordOffBits;
  localparam int UpperBits = WordBits - 2;
  localparam int PageUpperBits = PageWordBits - 2;
  wire [UpperBits-1:0] upper[Entries], next_upper[Entries];
  wire [1:0] low[Entries];
  for (genvar e = 0; e < Entries; e++) begin : g_address
    assign upper[e] = addr[e][Xlen-1:WordOffBits+2];
    assign next_upper[e] = upper[e] + UpperBits'(1);
    assign low[e] = addr[e][WordOffBits+:2];
  end
  function automatic logic same_upper(input logic [UpperBits-1:0] a, input logic [UpperBits-1:0] b);
    return a[PageUpperBits-1:0] == b[PageUpperBits-1:0]
        && (page_only || a[UpperBits-1:PageUpperBits] == b[UpperBits-1:PageUpperBits]);
  endfunction
  for (genvar a = 0; a < Entries; a++) begin : g_row
    for (genvar b = 0; b < Entries; b++) begin : g_column
      if (a == b) begin : g_self
        assign overlap[a][b] = 1'b1;
      end else if (a > b) begin : g_mirror
        assign overlap[a][b] = overlap[b][a];
      end else begin : g_pair
        wire [1:0] ab = low[a] - low[b];
        wire [1:0] ba = low[b] - low[a];
        wire equal_upper = same_upper(upper[a], upper[b]);
        assign overlap[a][b] = (ab <= span[b] && (low[a] >= low[b] ? equal_upper : same_upper(
            upper[a], next_upper[b]
        ))) || (ba <= span[a] && (low[b] >= low[a] ? equal_upper : same_upper(
            upper[b], next_upper[a]
        )));
      end
    end
  end
endmodule

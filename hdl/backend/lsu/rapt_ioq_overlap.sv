// Overlap of short, circular word ranges. Each access spans at most
// four words. Split each word index into a two-bit offset and an upper chunk.
// A short range can cross at most one chunk boundary; share that successor
// across comparisons instead of building full-width successors for each offset.
module rapt_ioq_overlap #(
    parameter int Xlen = 32,
    parameter int Entries = 8,
    parameter int WordOffBits = 2,
    parameter int PageOffBits = 12,
    // In square mode ColEntries must equal Entries; addr/span serve both axes.
    parameter bit Rectangular = 1'b0,
    parameter int ColEntries = Entries,
    // Specialize fixed page-only users even when synthesis retains hierarchy.
    parameter bit PageOnly = 1'b0
) (
    input logic [Xlen-1:0] addr[Entries],
    input logic [1:0] span[Entries],
    input logic page_only,
    output logic [ColEntries-1:0] overlap[Entries],
    input logic [Xlen-1:0] col_addr[ColEntries] = '{default: '0},
    input logic [1:0] col_span[ColEntries] = '{default: '0}
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
  // Square mode aliases the column set and keeps self/mirrored pairs as wires.
  // Rectangular mode compares independent row/column sets, including a == b.
  wire [UpperBits-1:0] column_upper[ColEntries], column_next[ColEntries];
  wire [1:0] column_low[ColEntries], column_span[ColEntries];
  for (genvar e = 0; e < ColEntries; e++) begin : g_column_address
    if (Rectangular) begin : g_independent
      assign column_upper[e] = col_addr[e][Xlen-1:WordOffBits+2];
      assign column_next[e] = column_upper[e] + UpperBits'(1);
      assign column_low[e] = col_addr[e][WordOffBits+:2];
      assign column_span[e] = col_span[e];
    end else begin : g_shared
      wire unused_column = &{1'b0, col_addr[e], col_span[e]};
      assign column_upper[e] = upper[e];
      assign column_next[e] = next_upper[e];
      assign column_low[e] = low[e];
      assign column_span[e] = span[e];
    end
  end
  function automatic logic same_upper(input logic [UpperBits-1:0] a, input logic [UpperBits-1:0] b);
    return a[PageUpperBits-1:0] == b[PageUpperBits-1:0]
        && (PageOnly || page_only || a[UpperBits-1:PageUpperBits] == b[UpperBits-1:PageUpperBits]);
  endfunction
  for (genvar a = 0; a < Entries; a++) begin : g_row
    for (genvar b = 0; b < ColEntries; b++) begin : g_column
      if (!Rectangular && a == b) begin : g_self
        assign overlap[a][b] = 1'b1;
      end else if (!Rectangular && a > b) begin : g_mirror
        assign overlap[a][b] = overlap[b][a];
      end else begin : g_pair
        wire [1:0] ab = low[a] - column_low[b];
        wire [1:0] ba = column_low[b] - low[a];
        wire equal_upper = same_upper(upper[a], column_upper[b]);
        assign overlap[a][b] = (ab <= column_span[b] && (low[a] >= column_low[b] ? equal_upper : same_upper(
            upper[a], column_next[b]
        ))) || (ba <= span[a] && (column_low[b] >= low[a] ? equal_upper : same_upper(
            column_upper[b], next_upper[a]
        )));
      end
    end
  end
endmodule

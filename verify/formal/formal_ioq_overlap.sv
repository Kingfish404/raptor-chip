`include "rapt.svh"

// Every directed/self/mirrored pair, arbitrary full-width addresses and every
// two-bit span. The reference is the old circular-distance definition.
module formal_ioq_overlap #(
    parameter int Xlen = `RAPT_XLEN,
    parameter int Entries = 3,
    parameter int WordOffBits = $clog2(Xlen / 8)
) (
    input logic [Xlen-1:0] addr[Entries],
    input logic [1:0] span[Entries],
    input logic page_only,
    output logic mismatch
);
  localparam int W = Xlen - WordOffBits;
  localparam int P = 12 - WordOffBits;
  wire [Entries-1:0] overlap[Entries];
  rapt_ioq_overlap #(
      .Xlen(Xlen),
      .Entries(Entries),
      .WordOffBits(WordOffBits)
  ) dut (
      .*
  );
  always_comb begin
    mismatch = 0;
    for (int a = 0; a < Entries; a++) begin
      for (int b = 0; b < Entries; b++) begin
        automatic logic [W-1:0] ab, ba;
        automatic logic [P-1:0] pab, pba;
        automatic logic expected;
        ab = addr[a][Xlen-1:WordOffBits] - addr[b][Xlen-1:WordOffBits];
        ba = addr[b][Xlen-1:WordOffBits] - addr[a][Xlen-1:WordOffBits];
        pab = P'(ab);
        pba = P'(ba);
        expected = page_only ? (pab <= P'(span[b]) || pba <= P'(span[a]))
            : (ab <= W'(span[b]) || ba <= W'(span[a]));
        mismatch |= overlap[a][b] != expected;
      end
    end
  end
endmodule

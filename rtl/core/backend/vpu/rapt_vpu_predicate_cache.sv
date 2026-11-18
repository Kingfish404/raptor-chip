// One predicate byte, tagged by element index. The owner must clear the cache
// on each new instruction and must not fill it if its source can be modified
// before all bits in that byte are consumed.
module rapt_vpu_predicate_cache #(
    parameter int IndexBits = 8,
    parameter bit Enable = 1
) (
    input logic clock,
    input logic reset,
    input logic clear,
    input logic [IndexBits-1:0] index,
    input logic fill,
    input logic [7:0] fill_data,
    output logic hit,
    output logic bit_value
);
  logic valid_q;
  logic [IndexBits-4:0] tag_q;
  logic [7:0] data_q;

  assign hit = Enable && valid_q && tag_q == index[IndexBits-1:3];
  assign bit_value = data_q[index[2:0]];

  always_ff @(posedge clock) begin
    if (reset || clear) begin
      valid_q <= 1'b0;
      tag_q <= '0;
      data_q <= '0;
    end else if (fill && Enable) begin
      valid_q <= 1'b1;
      tag_q <= index[IndexBits-1:3];
      data_q <= fill_data;
    end
  end
endmodule

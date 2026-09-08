// Reuse a live matching line, otherwise an invalid candidate, otherwise
// the replacement-policy victim. Way zero is a valid result, not a sentinel.
module rapt_cache_fill_select #(
    parameter int Ways = 2,
    parameter int WayBits = Ways > 1 ? $clog2(Ways) : 1
) (
    input logic [Ways-1:0] match_way,
    input logic [Ways-1:0] valid_way,
    input logic [WayBits-1:0] victim,
    output logic [WayBits-1:0] selected
);
  always_comb begin
    selected = victim;
    for (int way = Ways - 1; way >= 0; way--) if (!valid_way[way]) selected = WayBits'(way);
    for (int way = Ways - 1; way >= 0; way--) if (match_way[way]) selected = WayBits'(way);
  end
endmodule

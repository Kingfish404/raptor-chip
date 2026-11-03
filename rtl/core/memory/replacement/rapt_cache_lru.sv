// Multi-query true LRU, interface-compatible with rapt_cache_plru.
// Each set keeps one bit per way pair (i < j): set when way j was used after
// way i. A touch makes its way newer than every other way; update ports are
// applied in ascending order, so a higher port wins on pairs both ports touch.
// The victim is the unique way that every other way is newer than.
module rapt_cache_lru #(
    parameter int Ways = 4,
    parameter int SetBits = 4,
    parameter int ReadPorts = 2,
    parameter int UpdatePorts = 2,
    parameter int WayBits = $clog2(Ways)
) (
    input logic clock,
    input logic reset,
    input logic invalidate,
    input logic [SetBits-1:0] read_set[ReadPorts],
    output logic [WayBits-1:0] victim[ReadPorts],
    input logic [UpdatePorts-1:0] update_valid,
    input logic [SetBits-1:0] update_set[UpdatePorts],
    input logic [WayBits-1:0] update_way[UpdatePorts]
);
  localparam int Sets  = 2 ** SetBits;
  localparam int Pairs = Ways * (Ways - 1) / 2;
  logic [Pairs-1:0] newer[Sets];
  if (!(Ways >= 2 && WayBits == $clog2(
          Ways
      ) && SetBits > 0 && ReadPorts > 0 && UpdatePorts > 0)) begin : g_invalid_config
    $error("Invalid rapt_cache_lru configuration");
  end

  function automatic int pair_index(int older, int younger);
    return older * Ways - older * (older + 1) / 2 + younger - older - 1;
  endfunction

  for (genvar set_idx = 0; set_idx < Sets; set_idx++) begin : g_set
    for (genvar i = 0; i < Ways - 1; i++) begin : g_older
      for (genvar j = i + 1; j < Ways; j++) begin : g_younger
        localparam int PairIndex = i * Ways - i * (i + 1) / 2 + j - i - 1;
        always_ff @(posedge clock) begin
          if (reset || invalidate) newer[set_idx][PairIndex] <= 1'b0;
          else begin
            for (int port_idx = 0; port_idx < UpdatePorts; port_idx++) begin
              if (update_valid[port_idx] && update_set[port_idx] == SetBits'(set_idx)) begin
                if (update_way[port_idx] == WayBits'(i)) newer[set_idx][PairIndex] <= 1'b0;
                if (update_way[port_idx] == WayBits'(j)) newer[set_idx][PairIndex] <= 1'b1;
              end
            end
          end
        end
      end
    end
  end

  for (genvar port_idx = 0; port_idx < ReadPorts; port_idx++) begin : g_read
    logic [Ways-1:0] oldest;
    always_comb begin
      oldest = '1;
      for (int way = 0; way < Ways; way++) begin
        for (int other = 0; other < Ways; other++) begin
          if (other > way && !newer[read_set[port_idx]][pair_index(way, other)]) oldest[way] = 1'b0;
          if (other < way && newer[read_set[port_idx]][pair_index(other, way)]) oldest[way] = 1'b0;
        end
      end
      victim[port_idx] = '0;
      for (int way = Ways - 1; way >= 0; way--) if (oldest[way]) victim[port_idx] = WayBits'(way);
    end
  end
endmodule

// Multi-query tree PLRU. Bits record the most recently used child.
// Only nodes on an accessed leaf's path change. Update ports are applied
// in ascending order; a higher port wins only on nodes both ports touch.
module rapt_cache_plru #(
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
    output wire [WayBits-1:0] victim[ReadPorts],
    input logic [UpdatePorts-1:0] update_valid,
    input logic [SetBits-1:0] update_set[UpdatePorts],
    input logic [WayBits-1:0] update_way[UpdatePorts]
);
  localparam int Sets  = 2 ** SetBits;
  localparam int Nodes = Ways - 1;
  logic [Nodes-1:0] recent[Sets];
  if (!(Ways >= 2 && (Ways & (Ways - 1)) == 0 && WayBits == $clog2(
          Ways
      ) && SetBits > 0 && ReadPorts > 0 && UpdatePorts > 0)) begin : g_invalid_config
    $error("Invalid rapt_cache_plru configuration");
  end

  for (genvar set_idx = 0; set_idx < Sets; set_idx++) begin : g_set
    for (genvar level = 0; level < WayBits; level++) begin : g_level
      for (genvar node = 0; node < 2 ** level; node++) begin : g_node
        localparam int NodeIndex = (2 ** level) - 1 + node;
        always_ff @(posedge clock) begin
          if (reset || invalidate) recent[set_idx][NodeIndex] <= 1'b0;
          else begin
            for (int port_idx = 0; port_idx < UpdatePorts; port_idx++) begin
              if (update_valid[port_idx] && update_set[port_idx] == SetBits'(set_idx)
                  && ((WayBits+1)'(update_way[port_idx]) >> (WayBits - level))
                     == (WayBits+1)'(node))
                recent[set_idx][NodeIndex] <= update_way[port_idx][WayBits-level-1];
            end
          end
        end
      end
    end
  end

  for (genvar port_idx = 0; port_idx < ReadPorts; port_idx++) begin : g_read
    wire [WayBits-1:0] path[WayBits+1];
    assign path[0] = '0;
    for (genvar level = 0; level < WayBits; level++) begin : g_level
      assign path[level+1] = (path[level] << 1)
          | WayBits'(!recent[read_set[port_idx]][(2 ** level) - 1 + int'(path[level])]);
    end
    assign victim[port_idx] = path[WayBits];
  end
endmodule

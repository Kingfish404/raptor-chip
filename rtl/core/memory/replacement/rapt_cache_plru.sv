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
`ifdef FORMAL
    input logic [WayBits-1:0] update_way[UpdatePorts],
    output wire [Ways-2:0] formal_recent[2**SetBits]
`else
    input logic [WayBits-1:0] update_way[UpdatePorts]
`endif
);
  localparam int Sets  = 2 ** SetBits;
  localparam int Nodes = Ways - 1;
`ifdef FORMAL
  localparam bit UseIndexedArray = 1'b0;
`else
  localparam bit UseIndexedArray = (UpdatePorts == 1) && (Sets >= 16);
`endif

  if (!(Ways >= 2 && (Ways & (Ways - 1)) == 0 && WayBits == $clog2(
          Ways
      ) && SetBits > 0 && ReadPorts > 0 && UpdatePorts > 0)) begin : g_invalid_config
    $error("Invalid rapt_cache_plru configuration");
  end

  logic [Nodes-1:0] port_recent[ReadPorts];

  if (UseIndexedArray) begin : g_ram
    // Single-port indexed updates map to distributed RAM with a reset-valid
    // vector, matching rapt_cache_nru without per-node flip-flops or mux trees.
`ifdef SYNTHESIS
    localparam int PhysSets = (`RAPT_FPGA_LUTRAM && Sets < 32) ? 32 : Sets;
`else
    localparam int PhysSets = Sets;
`endif
    localparam int PhysSetBits = $clog2(PhysSets);
    logic [Nodes-1:0] recent_ram[PhysSets];
    logic [Sets-1:0] initialized;
    logic [Nodes-1:0] cur_recent, next_recent;
    wire [PhysSetBits-1:0] phys_update_set = PhysSetBits'(update_set[0]);

    assign cur_recent = initialized[update_set[0]] ? recent_ram[phys_update_set] : '0;
    for (genvar level = 0; level < WayBits; level++) begin : g_upd_level
      for (genvar node = 0; node < 2 ** level; node++) begin : g_upd_node
        localparam int NodeIndex = (2 ** level) - 1 + node;
        wire node_hit = ((WayBits + 1)'(update_way[0]) >> (WayBits - level))
            == (WayBits + 1)'(node);
        assign next_recent[NodeIndex] = node_hit
            ? update_way[0][WayBits - level - 1] : cur_recent[NodeIndex];
      end
    end

    always_ff @(posedge clock) begin
      if (reset || invalidate) initialized <= '0;
      else if (update_valid[0]) initialized[update_set[0]] <= 1'b1;
    end
    always_ff @(posedge clock) begin
      if (update_valid[0] && !reset && !invalidate) recent_ram[phys_update_set] <= next_recent;
    end

    for (genvar port_idx = 0; port_idx < ReadPorts; port_idx++) begin : g_port_read
      wire [PhysSetBits-1:0] phys_read_set = PhysSetBits'(read_set[port_idx]);
      assign port_recent[port_idx] = initialized[read_set[port_idx]]
          ? recent_ram[phys_read_set] : '0;
    end
  end else begin : g_flops
    logic [Nodes-1:0] recent[Sets];
`ifdef FORMAL
    // Observation only: expose every node for the independent formal model.
    assign formal_recent = recent;
`endif
    for (genvar set_idx = 0; set_idx < Sets; set_idx++) begin : g_set
      for (genvar level = 0; level < WayBits; level++) begin : g_level
        for (genvar node = 0; node < 2 ** level; node++) begin : g_node
          localparam int NodeIndex = (2 ** level) - 1 + node;
          always_ff @(posedge clock) begin
            if (reset || invalidate) recent[set_idx][NodeIndex] <= 1'b0;
            else begin
              for (int port_idx = 0; port_idx < UpdatePorts; port_idx++) begin
                if (update_valid[port_idx] && update_set[port_idx] == SetBits'(set_idx)
                    && ((WayBits + 1)'(update_way[port_idx]) >> (WayBits - level))
                       == (WayBits + 1)'(node))
                  recent[set_idx][NodeIndex] <= update_way[port_idx][WayBits-level-1];
              end
            end
          end
        end
      end
    end
    for (genvar port_idx = 0; port_idx < ReadPorts; port_idx++) begin : g_port_read
      assign port_recent[port_idx] = recent[read_set[port_idx]];
    end
  end

  // Select each query's 1D node vector once, then slice per tree level so
  // synthesis builds tiny 2**level:1 muxes instead of 2D set-and-node muxes.
  for (genvar port_idx = 0; port_idx < ReadPorts; port_idx++) begin : g_read
    wire [WayBits-1:0] path[WayBits+1];
    assign path[0] = '0;
    for (genvar level = 0; level < WayBits; level++) begin : g_level
      logic node_recent;
      if (level == 0) begin : g_root
        assign node_recent = port_recent[port_idx][0];
      end else begin : g_inner
        localparam int LevelNodes = 2 ** level;
        localparam int Lo = LevelNodes - 1;
        localparam int Hi = Lo + LevelNodes - 1;
        wire [LevelNodes-1:0] level_bits = port_recent[port_idx][Hi:Lo];
        wire [level-1:0] level_idx = path[level][level-1:0];
        assign node_recent = level_bits[level_idx];
      end
      assign path[level+1] = (path[level] << 1) | WayBits'(!node_recent);
    end
    assign victim[port_idx] = path[WayBits];
  end
endmodule

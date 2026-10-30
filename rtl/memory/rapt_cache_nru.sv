`include "rapt_sva.svh"

// One recent bit per way. Touching the last cold way starts a new epoch,
// retaining only the touched way. The caller merges mutually exclusive hit
// and install updates before this single indexed write port.
module rapt_cache_nru #(
    parameter int Ways = 8,
    parameter int SetBits = 6,
    parameter int ReadPorts = 2,
    parameter int WayBits = $clog2(Ways)
) (
    input logic clock,
    input logic reset,
    input logic invalidate,
    input logic [SetBits-1:0] read_set[ReadPorts],
    output logic [WayBits-1:0] victim[ReadPorts],
    input logic update_valid,
    input logic [SetBits-1:0] update_set,
    input logic [WayBits-1:0] update_way
);
  localparam int Sets = 2 ** SetBits;
  logic [Ways-1:0] recent[Sets];
  logic [Sets-1:0] initialized;
  logic [Ways-1:0] touched, next_recent;

  if (!(Ways >= 2 && (Ways & (Ways - 1)) == 0 && SetBits > 0 && WayBits == $clog2(
          Ways
      ) && ReadPorts > 0)) begin : g_invalid_config
    $error("Invalid rapt_cache_nru configuration");
  end

  assign touched = (initialized[update_set] ? recent[update_set] : '0)
      | (Ways'(1) << update_way);
  assign next_recent = (&touched) ? (Ways'(1) << update_way) : touched;
  always_ff @(posedge clock) begin
    if (reset || invalidate) initialized <= '0;
    else if (update_valid) initialized[update_set] <= 1'b1;
  end
  always_ff @(posedge clock) begin
    if (update_valid && !reset && !invalidate) recent[update_set] <= next_recent;
  end

  for (genvar port_idx = 0; port_idx < ReadPorts; port_idx++) begin : g_read
    always_comb begin
      victim[port_idx] = '0;
      if (initialized[read_set[port_idx]]) begin
        for (int way = Ways - 1; way >= 0; way--)
        if (!recent[read_set[port_idx]][way]) victim[port_idx] = WayBits'(way);
      end
    end
  end
endmodule

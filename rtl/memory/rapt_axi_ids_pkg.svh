`ifndef RAPT_AXI_IDS_PKG_SVH
`define RAPT_AXI_IDS_PKG_SVH

// Read response owners on the memory AXI link. The four MSHR IDs occupy
// 8..11; the low two bits identify the individual miss slot.
package rapt_axi_ids_pkg;
  localparam logic [3:0] L1I = 4'd1;
  localparam logic [3:0] L1D = 4'd2;
  localparam logic [3:0] TLBI = 4'd3;
  localparam logic [3:0] TLBD = 4'd4;
  localparam logic [3:0] MshrBase = 4'd8;
  localparam logic [3:0] MshrMask = 4'hc;
endpackage

`endif

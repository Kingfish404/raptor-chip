// Two independent, clocked read/write ports sharing one memory array.
// Each enabled port either writes at the rising edge or registers a read
// result at that edge. Read outputs hold when their port is idle or writes.
// The caller must avoid same-address cross-port accesses when either port
// writes: their result is device-dependent on both FPGA BRAM and SRAM macros.
// There is no array reset, so users needing reset values track validity
// outside this module.
module rapt_sram_2rw #(
    parameter int ADDR_WIDTH = 5,
    parameter int DATA_WIDTH = 64
) (
    input logic clock,
    input logic a_en,
    input logic a_wen,
    input logic [ADDR_WIDTH-1:0] a_addr,
    input logic [DATA_WIDTH-1:0] a_wdata,
    output logic [DATA_WIDTH-1:0] a_rdata,
    input logic b_en,
    input logic b_wen,
    input logic [ADDR_WIDTH-1:0] b_addr,
    input logic [DATA_WIDTH-1:0] b_wdata,
    output logic [DATA_WIDTH-1:0] b_rdata
);
  localparam int Depth = 1 << ADDR_WIDTH;
  (* ram_style = "block" *) logic [DATA_WIDTH-1:0] mem[Depth];

  always_ff @(posedge clock) begin
    if (a_en) begin
      if (a_wen) mem[a_addr] <= a_wdata;
      else a_rdata <= mem[a_addr];
    end
  end

  always_ff @(posedge clock) begin
    if (b_en) begin
      if (b_wen) mem[b_addr] <= b_wdata;
      else b_rdata <= mem[b_addr];
    end
  end
endmodule

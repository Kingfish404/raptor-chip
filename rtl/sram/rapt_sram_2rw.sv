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
    input rapt_pkg::sram_ctrl_t sram_ctrl_i,
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
`ifdef RAPT_USE_SRAM_MACRO
  if (Depth == 32 && DATA_WIDTH == 64) begin : g_32x64
    rapt_openram_2rw_32x64 u_sram (
        .ctrl (sram_ctrl_i),
        .clk0 (clock),
        .csb0 (~a_en),
        .web0 (~a_wen),
        .addr0(a_addr),
        .din0 (a_wdata),
        .dout0(a_rdata),
        .clk1 (clock),
        .csb1 (~b_en),
        .web1 (~b_wen),
        .addr1(b_addr),
        .din1 (b_wdata),
        .dout1(b_rdata)
    );
  end else begin : g_unsupported
    rapt_unsupported_sram_shape #(
        .DEPTH(Depth),
        .DATA_WIDTH(DATA_WIDTH)
    ) u_unsupported_sram_shape ();
    assign a_rdata = 'x;
    assign b_rdata = 'x;
  end
`else
  wire unused_sram_ctrl = ^sram_ctrl_i;
  // Live-value table (LVT) decomposition: each bank has a single write port
  // and a single clocked read port so synthesizers infer clean 1R1W RAMs
  // without synthesis pragmas or multi-write-process FF dissolution.
  logic [DATA_WIDTH-1:0] bank_a_ra[Depth];
  logic [DATA_WIDTH-1:0] bank_a_rb[Depth];
  logic [DATA_WIDTH-1:0] bank_b_ra[Depth];
  logic [DATA_WIDTH-1:0] bank_b_rb[Depth];
  logic [DATA_WIDTH-1:0] a_rdata_a;
  logic [DATA_WIDTH-1:0] a_rdata_b;
  logic [DATA_WIDTH-1:0] b_rdata_a;
  logic [DATA_WIDTH-1:0] b_rdata_b;
  logic [Depth-1:0] owner_b;
  logic a_sel_b_q;
  logic b_sel_b_q;

  always_ff @(posedge clock) begin
    if (a_en && a_wen) bank_a_ra[a_addr] <= a_wdata;
    if (a_en && !a_wen) a_rdata_a <= bank_a_ra[a_addr];
  end

  always_ff @(posedge clock) begin
    if (a_en && a_wen) bank_a_rb[a_addr] <= a_wdata;
    if (b_en && !b_wen) b_rdata_a <= bank_a_rb[b_addr];
  end

  always_ff @(posedge clock) begin
    if (b_en && b_wen) bank_b_ra[b_addr] <= b_wdata;
    if (a_en && !a_wen) a_rdata_b <= bank_b_ra[a_addr];
  end

  always_ff @(posedge clock) begin
    if (b_en && b_wen) bank_b_rb[b_addr] <= b_wdata;
    if (b_en && !b_wen) b_rdata_b <= bank_b_rb[b_addr];
  end

  always_ff @(posedge clock) begin
    if (a_en && a_wen) owner_b[a_addr] <= 1'b0;
    if (b_en && b_wen) owner_b[b_addr] <= 1'b1;
    if (a_en && !a_wen) a_sel_b_q <= owner_b[a_addr];
    if (b_en && !b_wen) b_sel_b_q <= owner_b[b_addr];
  end

  assign a_rdata = a_sel_b_q ? a_rdata_b : a_rdata_a;
  assign b_rdata = b_sel_b_q ? b_rdata_b : b_rdata_a;
`endif
endmodule

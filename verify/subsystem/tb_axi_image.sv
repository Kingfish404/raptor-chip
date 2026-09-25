`include "rapt_soc_if.svh"

// DPI-free backing memory shared by the BE and MEM trace experiments.
module tb_axi_image #(
    parameter int XLEN = `RAPT_XLEN
) (
    input logic clock,
    input logic reset,
    axi4_if.slave axi,
    output logic sim_finish,
    output logic [31:0] sim_exit_code
);
  rapt_tb_mem #(
      .XLEN(XLEN)
  ) memory_model (
      .clock,
      .reset,
      .awid(axi.awid),
      .awaddr(axi.awaddr),
      .awlen(axi.awlen),
      .awsize(axi.awsize),
      .awburst(axi.awburst),
      .awvalid(axi.awvalid),
      .awready(axi.awready),
      .wdata(axi.wdata),
      .wstrb(axi.wstrb),
      .wlast(axi.wlast),
      .wvalid(axi.wvalid),
      .wready(axi.wready),
      .bid(axi.bid),
      .bresp(axi.bresp),
      .bvalid(axi.bvalid),
      .bready(axi.bready),
      .arid(axi.arid),
      .araddr(axi.araddr),
      .arlen(axi.arlen),
      .arsize(axi.arsize),
      .arburst(axi.arburst),
      .arvalid(axi.arvalid),
      .arready(axi.arready),
      .rid(axi.rid),
      .rdata(axi.rdata),
      .rresp(axi.rresp),
      .rlast(axi.rlast),
      .rvalid(axi.rvalid),
      .rready(axi.rready),
      .sim_finish,
      .sim_exit_code
  );

  initial begin
    string image_path;
    int loaded;
    if (!$value$plusargs("IMG=%s", image_path)) $fatal(1, "+IMG required");
    loaded = memory_model.load_bin(image_path, 32'h8000_0000);
    if (loaded <= 0) $fatal(1, "failed to load image %s", image_path);
  end
endmodule

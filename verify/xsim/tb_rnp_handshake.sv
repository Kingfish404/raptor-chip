`include "rapt.svh"
`include "rapt_soc_if.svh"
module tb_rnp_handshake;
  logic clock=0, reset=1;
  always #5 clock=~clock;
  axi4_if #(.XLEN(32),.ID_W(4)) cpu(), mem();
  logic [31:0] rnp_mdata,rnp_cdata;
  logic rnp_arvalid,rnp_arready,rnp_rvalid,rnp_rready;
  logic rnp_awvalid,rnp_awready,rnp_wvalid,rnp_wready,rnp_bvalid,rnp_bready;
  logic [3:0] rnp_wstrb;
  logic [1:0] rnp_rwstate;
  axi2rnp u_axi2rnp(
    .clk(clock),
    .reset(reset),
    .axi_arburst(cpu.arburst),
    .axi_arsize(cpu.arsize),
    .axi_arlen(cpu.arlen),
    .axi_arid(cpu.arid),
    .axi_araddr(cpu.araddr),
    .axi_arvalid(cpu.arvalid),
    .axi_arready(cpu.arready),
    .axi_rid(cpu.rid),
    .axi_rlast(cpu.rlast),
    .axi_rdata(cpu.rdata),
    .axi_rresp(cpu.rresp),
    .axi_rvalid(cpu.rvalid),
    .axi_rready(cpu.rready),
    .axi_awburst(cpu.awburst),
    .axi_awsize(cpu.awsize),
    .axi_awlen(cpu.awlen),
    .axi_awid(cpu.awid),
    .axi_awaddr(cpu.awaddr),
    .axi_awvalid(cpu.awvalid),
    .axi_awready(cpu.awready),
    .axi_wlast(cpu.wlast),
    .axi_wdata(cpu.wdata),
    .axi_wstrb(cpu.wstrb),
    .axi_wvalid(cpu.wvalid),
    .axi_wready(cpu.wready),
    .axi_bid(cpu.bid),
    .axi_bresp(cpu.bresp),
    .axi_bvalid(cpu.bvalid),
    .axi_bready(cpu.bready),
    .rnp_mdata(rnp_mdata),
    .rnp_cdata(rnp_cdata),
    .rnp_arvalid(rnp_arvalid),
    .rnp_arready(rnp_arready),
    .rnp_rvalid(rnp_rvalid),
    .rnp_rready(rnp_rready),
    .rnp_awvalid(rnp_awvalid),
    .rnp_awready(rnp_awready),
    .rnp_wstrb(rnp_wstrb),
    .rnp_wvalid(rnp_wvalid),
    .rnp_wready(rnp_wready),
    .rnp_bvalid(rnp_bvalid),
    .rnp_bready(rnp_bready),
    .rnp_rwstate(rnp_rwstate));
  rnp2axi u_rnp2axi(
    .clk(clock),
    .reset(reset),
    .axi_arburst(mem.arburst),
    .axi_arsize(mem.arsize),
    .axi_arlen(mem.arlen),
    .axi_arid(mem.arid),
    .axi_araddr(mem.araddr),
    .axi_arvalid(mem.arvalid),
    .axi_arready(mem.arready),
    .axi_rid(mem.rid),
    .axi_rlast(mem.rlast),
    .axi_rdata(mem.rdata),
    .axi_rresp(mem.rresp),
    .axi_rvalid(mem.rvalid),
    .axi_rready(mem.rready),
    .axi_awburst(mem.awburst),
    .axi_awsize(mem.awsize),
    .axi_awlen(mem.awlen),
    .axi_awid(mem.awid),
    .axi_awaddr(mem.awaddr),
    .axi_awvalid(mem.awvalid),
    .axi_awready(mem.awready),
    .axi_wlast(mem.wlast),
    .axi_wdata(mem.wdata),
    .axi_wstrb(mem.wstrb),
    .axi_wvalid(mem.wvalid),
    .axi_wready(mem.wready),
    .axi_bid(mem.bid),
    .axi_bresp(mem.bresp),
    .axi_bvalid(mem.bvalid),
    .axi_bready(mem.bready),
    .rnp_mdata(rnp_mdata),
    .rnp_cdata(rnp_cdata),
    .rnp_arvalid(rnp_arvalid),
    .rnp_arready(rnp_arready),
    .rnp_rvalid(rnp_rvalid),
    .rnp_rready(rnp_rready),
    .rnp_awvalid(rnp_awvalid),
    .rnp_awready(rnp_awready),
    .rnp_wstrb(rnp_wstrb),
    .rnp_wvalid(rnp_wvalid),
    .rnp_wready(rnp_wready),
    .rnp_bvalid(rnp_bvalid),
    .rnp_bready(rnp_bready),
    .rnp_rwstate(rnp_rwstate));
  `include "tb_common.svh"
  initial begin
    cpu.arvalid=0; cpu.rready=0; cpu.awvalid=0; cpu.wvalid=0; cpu.bready=0;
    cpu.araddr='h20000000; cpu.arid=5; cpu.arlen=0; cpu.arsize=2; cpu.arburst=0;
    cpu.awaddr='h80000000; cpu.awid=7; cpu.awlen=0; cpu.awsize=2; cpu.awburst=0;
    cpu.wdata='h12345678; cpu.wstrb=15; cpu.wlast=1;
    mem.arready=0; mem.rvalid=0; mem.rdata='habcdef01; mem.rid=0; mem.rresp=0; mem.rlast=1;
    mem.awready=0; mem.wready=1; mem.bvalid=0; mem.bid=0; mem.bresp=0;
    tick(4); reset=0; tick(2);
    // Simultaneous AW/W with WREADY high must not consume data in address phase.
    cpu.awvalid=1; cpu.wvalid=1;
    tick(2);
    repeat(4) begin
      check(!cpu.wready && !mem.wvalid,"RNP acknowledged W while transporting AW");
      check(mem.awvalid && mem.awaddr=='h80000000,"RNP AW payload missing");
      tick(1);
    end
    mem.awready=1; tick(1); cpu.awvalid=0; mem.awready=0;
    mem.wready=0; tick(2);
    repeat(4) begin
      check(mem.wvalid && mem.wlast && mem.wdata=='h12345678,"RNP W payload/last unstable under stall");
      tick(1);
    end
    mem.wready=1; tick(1); cpu.wvalid=0; mem.wready=0;
    // Changing the next address ID cannot change ownership of the pending B.
    cpu.awid=9; mem.bvalid=1; tick(2);
    repeat(4) begin
      check(cpu.bvalid && cpu.bid==7,"RNP lost accepted AW ID"); tick(1);
    end
    cpu.bready=1; tick(1); mem.bvalid=0; cpu.bready=0; tick(2);
    cpu.arvalid=1; mem.arready=1;
    for(int i=0;i<20;i++) begin
      if(cpu.arready) break;
      tick(1);
    end
    check(cpu.arready,"RNP AR missing");
    tick(1); cpu.arvalid=0; mem.arready=0; cpu.arid=10;
    mem.rvalid=1; tick(2);
    repeat(4) begin
      check(cpu.rvalid && cpu.rlast && cpu.rid==5 && cpu.rdata=='habcdef01,
            "RNP R ownership/last unstable under stall"); tick(1);
    end
    cpu.rready=1; tick(1); mem.rvalid=0; cpu.rready=0;
    tick(2);
    $display("PASS: RNP address/data serialization, stable R/W last and retained response IDs");
    $finish;
  end
  initial begin #10000; $fatal(1,"RNP handshake watchdog"); end
endmodule

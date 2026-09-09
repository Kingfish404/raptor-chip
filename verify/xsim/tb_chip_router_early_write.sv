`include "rapt.svh"
`include "rapt_soc_if.svh"
module tb_chip_router_early_write;
  localparam int XLEN=`RAPT_XLEN;
  logic clock=0, reset=1;
  always #5 clock=~clock;
  axi4_if core_axi(), offchip_axi();
  clint_bus_if clint_bus();
  plic_bus_if plic_bus();
  rapt_router dut(.*);
  `include "tb_common.svh"
  assign clint_bus.rdata='0;
  assign plic_bus.rdata='0;

  task automatic write_case(input int aw_delay,input int w_delay,input logic [1:0] response);
    bit aw_done,w_done;
    int aw_count,w_count;
    aw_done=0; w_done=0; aw_count=0; w_count=0;
    @(negedge clock);
    core_axi.awaddr=XLEN'('h80001000);
    core_axi.awid=7;
    core_axi.awlen=0;
    core_axi.awsize=3'($clog2(XLEN/8));
    core_axi.awburst=1;
    core_axi.awcache=4'he;
    core_axi.awvalid=1;
    core_axi.wdata=XLEN'('h12345678);
    core_axi.wstrb='1;
    core_axi.wlast=1;
    core_axi.wvalid=1;
    for(int cycle=0;cycle<20 && !(aw_done && w_done);cycle++) begin
      offchip_axi.awready=cycle>=aw_delay;
      offchip_axi.wready=cycle>=w_delay;
      @(posedge clock);
      if(core_axi.awvalid && core_axi.awready) begin aw_done=1; aw_count++; end
      if(core_axi.wvalid && core_axi.wready) begin w_done=1; w_count++; end
      #1;
      if(aw_done) core_axi.awvalid=0;
      if(w_done) core_axi.wvalid=0;
      @(negedge clock);
    end
    check(aw_count==1 && w_count==1,"AW/W not accepted exactly once");
    offchip_axi.awready=0; offchip_axi.wready=0;
    offchip_axi.bid=7; offchip_axi.bresp=response; offchip_axi.bvalid=1;
    #1;
    repeat(4) begin
      check(core_axi.bvalid && core_axi.bid==7 && core_axi.bresp==response,
            "B response lost after independent AW/W handshakes");
      check(!offchip_axi.bready,"B consumed while upstream stalled");
      tick(1);
    end
    core_axi.bready=1;
    #1;
    check(offchip_axi.bready,"B ready not forwarded");
    tick(1);
    core_axi.bready=0; offchip_axi.bvalid=0;
    tick(2);
  endtask
  initial begin
    core_axi.arvalid=0; core_axi.rready=0;
    core_axi.awvalid=0; core_axi.wvalid=0; core_axi.bready=0;
    offchip_axi.arready=0; offchip_axi.rvalid=0;
    offchip_axi.rid=0; offchip_axi.rdata=0; offchip_axi.rlast=0; offchip_axi.rresp=0;
    offchip_axi.awready=0; offchip_axi.wready=0; offchip_axi.bvalid=0;
    offchip_axi.bid=0; offchip_axi.bresp=0;
    tick(4); reset=0; tick(2);
    write_case(7,0,0);
    write_case(0,7,2);
    write_case(0,0,0);
    write_case(3,1,3);
    $display("PASS: router W-before-AW, AW-before-W, simultaneous and stalled B RV%0d",XLEN);
    $finish;
  end
endmodule

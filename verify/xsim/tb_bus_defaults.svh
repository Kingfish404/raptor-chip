`include "tb_core_bcast_defaults.svh"

task automatic init_bus_inputs;
  begin
    axi.arready = 1'b0;
    axi.rid = '0;
    axi.rlast = 1'b0;
    axi.rdata = '0;
    axi.rresp = 2'b00;
    axi.rvalid = 1'b0;
    axi.awready = 1'b0;
    axi.wready = 1'b0;
    axi.bid = '0;
    axi.bresp = 2'b00;
    axi.bvalid = 1'b0;

    l1i_bus.arvalid = 1'b0;
    l1i_bus.araddr = '0;
    l1i_bus.arburst = 1'b0;
    l1i_bus.awvalid = 1'b0;
    l1i_bus.awaddr = '0;
    l1i_bus.wvalid = 1'b0;
    l1i_bus.wdata = '0;
    l1i_bus.wstrb = '0;

    l1d_bus.arvalid = 1'b0;
    l1d_bus.araddr = '0;
    l1d_bus.rstrb = 8'h0f;
    l1d_bus.awvalid = 1'b0;
    l1d_bus.awaddr = '0;
    l1d_bus.wvalid = 1'b0;
    l1d_bus.wdata = '0;
    l1d_bus.wstrb = '0;

    init_csr_bcast_defaults('0, '0, 1'b0);
    init_cmu_bcast_defaults();
  end
endtask
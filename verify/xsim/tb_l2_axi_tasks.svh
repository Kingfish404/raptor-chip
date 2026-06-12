task automatic init_l2_axi(input bit upstream_bready_init);
  begin
    axi_s.arburst = 2'b01;
    axi_s.arsize = 3'd2;
    axi_s.arlen = 8'd0;
    axi_s.arid = '0;
    axi_s.araddr = '0;
    axi_s.arvalid = 1'b0;
    axi_s.rready = 1'b1;

    axi_s.awburst = 2'b01;
    axi_s.awsize = 3'd2;
    axi_s.awlen = 8'd0;
    axi_s.awid = '0;
    axi_s.awaddr = '0;
    axi_s.awvalid = 1'b0;
    axi_s.wlast = 1'b1;
    axi_s.wdata = '0;
    axi_s.wstrb = '0;
    axi_s.wvalid = 1'b0;
    axi_s.bready = upstream_bready_init;

    axi_m.arready = 1'b0;
    axi_m.rid = '0;
    axi_m.rlast = 1'b1;
    axi_m.rdata = '0;
    axi_m.rresp = 2'b00;
    axi_m.rvalid = 1'b0;

    axi_m.awready = 1'b0;
    axi_m.wready = 1'b0;
    axi_m.bid = '0;
    axi_m.bresp = 2'b00;
    axi_m.bvalid = 1'b0;
  end
endtask

task automatic send_l2_aw(input logic [XLEN-1:0] addr, input logic [IdW-1:0] id);
  begin
    axi_s.awaddr = addr;
    axi_s.awid = id;
    axi_s.awlen = 8'd0;
    axi_s.awsize = 3'd2;
    axi_s.awburst = 2'b01;
    axi_s.awvalid = 1'b1;
    do @(posedge clock); while (!axi_s.awready);
    #1;
    axi_s.awvalid = 1'b0;
  end
endtask

task automatic send_l2_w(input logic [XLEN-1:0] data, input logic [XLEN/8-1:0] strb);
  begin
    axi_s.wdata = data;
    axi_s.wstrb = strb;
    axi_s.wlast = 1'b1;
    axi_s.wvalid = 1'b1;
    do @(posedge clock); while (!axi_s.wready);
    #1;
    axi_s.wvalid = 1'b0;
    axi_s.wstrb = '0;
  end
endtask

task automatic send_l2_w_full(input logic [XLEN-1:0] data);
  begin
    send_l2_w(data, {(XLEN / 8){1'b1}});
  end
endtask

task automatic send_l2_ar_len(
    input logic [XLEN-1:0] addr,
    input logic [IdW-1:0] id,
    input logic [7:0] len,
    input logic [1:0] burst
);
  begin
    axi_s.araddr = addr;
    axi_s.arid = id;
    axi_s.arlen = len;
    axi_s.arsize = 3'd2;
    axi_s.arburst = burst;
    axi_s.arvalid = 1'b1;
    do @(posedge clock); while (!axi_s.arready);
    #1;
    axi_s.arvalid = 1'b0;
  end
endtask

task automatic send_l2_ar(input logic [XLEN-1:0] addr, input logic [IdW-1:0] id);
  begin
    send_l2_ar_len(addr, id, 8'd0, 2'b01);
  end
endtask

task automatic accept_l2_downstream_write(
    output logic [IdW-1:0] id_seen,
    output logic [XLEN-1:0] addr_seen,
    output logic [XLEN-1:0] data_seen,
    output logic [XLEN/8-1:0] strb_seen,
    output logic last_seen
);
  begin
    axi_m.awready = 1'b1;
    do @(posedge clock); while (!axi_m.awvalid);
    id_seen = axi_m.awid;
    addr_seen = axi_m.awaddr;
    #1;
    axi_m.awready = 1'b0;

    axi_m.wready = 1'b1;
    do @(posedge clock); while (!axi_m.wvalid);
    data_seen = axi_m.wdata;
    strb_seen = axi_m.wstrb;
    last_seen = axi_m.wlast;
    #1;
    axi_m.wready = 1'b0;
  end
endtask

task automatic return_l2_downstream_b(input logic [IdW-1:0] id, input logic [1:0] resp);
  begin
    axi_m.bid = id;
    axi_m.bresp = resp;
    axi_m.bvalid = 1'b1;
    do @(posedge clock); while (!axi_m.bready);
    #1;
    axi_m.bvalid = 1'b0;
    axi_m.bresp = 2'b00;
  end
endtask

task automatic accept_l2_downstream_ar(
    output logic [IdW-1:0] id_seen,
    output logic [XLEN-1:0] addr_seen,
    output logic [7:0] len_seen
);
  begin
    axi_m.arready = 1'b1;
    do @(posedge clock); while (!axi_m.arvalid);
    id_seen = axi_m.arid;
    addr_seen = axi_m.araddr;
    len_seen = axi_m.arlen;
    #1;
    axi_m.arready = 1'b0;
  end
endtask

task automatic return_l2_downstream_r(
    input logic [IdW-1:0] id,
    input logic [XLEN-1:0] data,
    input logic last
);
  begin
    axi_m.rid = id;
    axi_m.rdata = data;
    axi_m.rresp = 2'b00;
    axi_m.rlast = last;
    axi_m.rvalid = 1'b1;
    do @(posedge clock); while (!axi_m.rready);
    #1;
    axi_m.rvalid = 1'b0;
    axi_m.rlast = 1'b1;
  end
endtask
`include "rapt.svh"
`include "rapt_soc_if.svh"

// Register the outer AXI R channel before it enters the cache hierarchy.
// Two entries let a ready consumer accept one beat on every cycle while
// rready to the memory controller depends only on registered occupancy.
module rapt_axi_r_buffer #(
    parameter int XLEN = `RAPT_XLEN,
    parameter int ID_W = 4,
    parameter bit Enable = 1'b1
) (
    input logic clock,
    input logic reset,
    axi4_if.slave upstream,
    axi4_if.master downstream
);
  assign downstream.araddr = upstream.araddr;
  assign downstream.arid = upstream.arid;
  assign downstream.arlen = upstream.arlen;
  assign downstream.arsize = upstream.arsize;
  assign downstream.arburst = upstream.arburst;
  assign downstream.arcache = upstream.arcache;
  assign downstream.arvalid = upstream.arvalid;
  assign upstream.arready = downstream.arready;

  assign downstream.awaddr = upstream.awaddr;
  assign downstream.awid = upstream.awid;
  assign downstream.awlen = upstream.awlen;
  assign downstream.awsize = upstream.awsize;
  assign downstream.awburst = upstream.awburst;
  assign downstream.awcache = upstream.awcache;
  assign downstream.awvalid = upstream.awvalid;
  assign upstream.awready = downstream.awready;

  assign downstream.wdata = upstream.wdata;
  assign downstream.wstrb = upstream.wstrb;
  assign downstream.wlast = upstream.wlast;
  assign downstream.wvalid = upstream.wvalid;
  assign upstream.wready = downstream.wready;

  assign upstream.bid = downstream.bid;
  assign upstream.bresp = downstream.bresp;
  assign upstream.bvalid = downstream.bvalid;
  assign downstream.bready = upstream.bready;

  if (Enable) begin : g_buffered
    typedef struct packed {
      logic [ID_W-1:0] rid;
      logic [XLEN-1:0] data;
      logic [1:0] resp;
      logic last;
    } beat_t;
    beat_t beat[2];
    logic [1:0] count;
    logic head, tail;
    logic push, pop;

    assign downstream.rready = !reset && count != 2'd2;
    assign upstream.rvalid = count != 2'd0;
    assign upstream.rid = beat[head].rid;
    assign upstream.rdata = beat[head].data;
    assign upstream.rresp = beat[head].resp;
    assign upstream.rlast = beat[head].last;
    assign push = downstream.rvalid && downstream.rready;
    assign pop = upstream.rvalid && upstream.rready;

    always_ff @(posedge clock) begin
      if (reset) begin
        count <= '0;
        head <= 1'b0;
        tail <= 1'b0;
      end else begin
        if (push) begin
          beat[tail] <= '{rid: downstream.rid, data: downstream.rdata,
                          resp: downstream.rresp, last: downstream.rlast};
          tail <= !tail;
        end
        if (pop) head <= !head;
        unique case ({
          push, pop
        })
          2'b10: count <= count + 2'd1;
          2'b01: count <= count - 2'd1;
          default: ;
        endcase
      end
    end
`ifndef SYNTHESIS
    assert property (@(posedge clock) disable iff (reset) count <= 2'd2);
`endif
  end else begin : g_bypass
    assign upstream.rid = downstream.rid;
    assign upstream.rdata = downstream.rdata;
    assign upstream.rresp = downstream.rresp;
    assign upstream.rlast = downstream.rlast;
    assign upstream.rvalid = downstream.rvalid;
    assign downstream.rready = upstream.rready;
  end
endmodule

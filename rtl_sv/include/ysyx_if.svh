`ifndef YSYX_IF_SVH
`define YSYX_IF_SVH
`include "ysyx.svh"
`include "ysyx_if_if.svh"
`include "ysyx_id_if.svh"
`include "ysyx_rn_if.svh"
`include "ysyx_ro_if.svh"
`include "ysyx_ex_if.svh"

// lsu to l1d interface
interface lsu_l1d_if #(
    parameter int XLEN = `YSYX_XLEN,
    parameter int L1D_LEN = `YSYX_L1D_LEN
);
  logic [XLEN-1:0] raddr;
  logic [4:0] ralu;
  logic rvalid;

  logic [XLEN-1:0] rdata;
  logic rready;

  logic [XLEN-1:0] waddr;
  logic [4:0] walu;
  logic wvalid;
  logic [XLEN-1:0] wdata;

  modport master(
      output raddr, ralu, rvalid,
      input rdata, rready,
      output waddr, walu, wvalid, wdata
  );
  modport slave(input raddr, ralu, rvalid, output rdata, rready, input waddr, walu, wvalid, wdata);
endinterface

// instruction cache interface
interface l1i_bus_if #(
    parameter int XLEN = `YSYX_XLEN
);
  // load
  logic arvalid;
  logic [XLEN-1:0] araddr;
  logic rready;

  logic [XLEN-1:0] rdata;
  logic rvalid;
  logic rlast;

  modport master(output arvalid, araddr, input rready, rdata, rvalid, rlast);
  modport slave(input arvalid, araddr, output rready, rdata, rvalid, rlast);
endinterface

// data cache interface
interface l1d_bus_if #(
    parameter int XLEN = `YSYX_XLEN
);
  // load
  logic arvalid;
  logic [XLEN-1:0] araddr;
  logic [7:0] rstrb;
  logic rready;

  logic [XLEN-1:0] rdata;
  logic rvalid;
  logic rlast;

  // store
  logic awvalid;
  logic [XLEN-1:0] awaddr;
  logic wvalid;
  logic [XLEN-1:0] wdata;
  logic [7:0] wstrb;
  logic wready;

  modport master(
      output arvalid, araddr, rstrb,
      input rready,
      input rdata, rvalid, rlast,

      output awvalid, awaddr, wvalid, wdata, wstrb,
      input wready
  );
  modport slave(
      input arvalid, araddr, rstrb,
      output rready,
      output rdata, rvalid, rlast,

      input awvalid, awaddr, wvalid, wdata, wstrb,
      output wready
  );
endinterface

// final commit boardcast
interface cmu_pipe_if #(
    parameter unsigned RLEN = `YSYX_REG_LEN,
    parameter int XLEN = `YSYX_XLEN
);
  logic [XLEN-1:0] rpc;
  logic [XLEN-1:0] cpc;
  logic [RLEN-1:0] rd;

  logic ben;
  logic jen;
  logic jren;
  logic btaken;

  logic fence_time;
  logic fence_i;

  logic flush_pipe;

  modport in(input rpc, cpc, rd, ben, jen, jren, btaken, fence_time, fence_i, flush_pipe);
  modport out(output rpc, cpc, rd, ben, jen, jren, btaken, fence_time, fence_i, flush_pipe);
endinterface

`endif

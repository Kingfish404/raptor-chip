`include "rapt.svh"

// Minimal PLIC interface for peripheral-only proofs. Defining the
// production include guard keeps unrelated AXI/cache interfaces out of the
// formal cone while preserving the RTL modport contract.
`ifndef RAPT_SOC_IF_SVH
`define RAPT_SOC_IF_SVH

interface plic_bus_if #(
    parameter int XLEN = `RAPT_XLEN,
    parameter int NDEV = 3,
    parameter int NCTX = 2,
    parameter int NHART = (NCTX + 1) / 2
);
  logic [NDEV:0] ext_irq;
  logic [XLEN-1:0] araddr, rdata, awaddr, wdata;
  logic [XLEN/8-1:0] wstrb;
  logic ar_commit, wvalid;
  logic [NHART-1:0] meip, seip;
  modport slave(
      input ext_irq, araddr, ar_commit, awaddr, wdata, wstrb, wvalid,
      output rdata, meip, seip
  );
endinterface

`endif

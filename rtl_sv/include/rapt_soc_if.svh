/* verilator lint_off DECLFILENAME */
`ifndef RAPT_SOC_IF_SVH
`define RAPT_SOC_IF_SVH

`include "rapt.svh"
`include "rapt_soc.svh"

/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNUSEDPARAM */
/* verilator lint_off UNDRIVEN */

interface axi4_if #(
    parameter int XLEN = `RAPT_XLEN,
    parameter int ID_W = 4
);
  logic [       1:0] arburst;
  logic [       2:0] arsize;
  logic [       7:0] arlen;
  logic [  ID_W-1:0] arid;
  logic [  XLEN-1:0] araddr;
  logic              arvalid;
  logic              arready;

  logic [  ID_W-1:0] rid;
  logic              rlast;
  logic [  XLEN-1:0] rdata;
  logic [       1:0] rresp;
  logic              rvalid;
  logic              rready;

  logic [       1:0] awburst;
  logic [       2:0] awsize;
  logic [       7:0] awlen;
  logic [  ID_W-1:0] awid;
  logic [  XLEN-1:0] awaddr;
  logic              awvalid;
  logic              awready;

  logic              wlast;
  logic [  XLEN-1:0] wdata;
  logic [XLEN/8-1:0] wstrb;
  logic              wvalid;
  logic              wready;

  logic [  ID_W-1:0] bid;
  logic [       1:0] bresp;
  logic              bvalid;
  logic              bready;

  modport master(
      output arburst, arsize, arlen, arid, araddr, arvalid,
      input arready,

      input rid, rlast, rdata, rresp, rvalid,
      output rready,

      output awburst, awsize, awlen, awid, awaddr, awvalid,
      input awready,

      output wlast, wdata, wstrb, wvalid,
      input wready,

      input bid, bresp, bvalid,
      output bready
  );

  modport slave(
      input arburst, arsize, arlen, arid, araddr, arvalid,
      output arready,

      output rid, rlast, rdata, rresp, rvalid,
      input rready,

      input awburst, awsize, awlen, awid, awaddr, awvalid,
      output awready,

      input wlast, wdata, wstrb, wvalid,
      output wready,

      output bid, bresp, bvalid,
      input bready
  );
endinterface

interface clint_bus_if #(
    parameter int XLEN = `RAPT_XLEN
);
  logic [XLEN-1:0] araddr;
  logic [XLEN-1:0] rdata;

  logic [XLEN-1:0] awaddr;
  logic [XLEN-1:0] wdata;
  logic            wvalid;

  logic            timer_int;
  logic            sw_int;

  modport master(output araddr, input rdata, output awaddr, wdata, wvalid, input timer_int, sw_int);

  modport slave(input araddr, output rdata, input awaddr, wdata, wvalid, output timer_int, sw_int);
endinterface

interface plic_bus_if #(
    parameter int XLEN  = `RAPT_XLEN,
    parameter int NDEV  = `RAPT_PLIC_NDEV,
    parameter int NCTX  = `RAPT_PLIC_NCTX,
    parameter int NHART = (NCTX + 1) / 2
);
  logic [   NDEV:0] ext_irq;

  logic [ XLEN-1:0] araddr;
  logic [ XLEN-1:0] rdata;
  logic             ar_commit;

  logic [ XLEN-1:0] awaddr;
  logic [ XLEN-1:0] wdata;
  logic             wvalid;

  logic [NHART-1:0] meip;
  logic [NHART-1:0] seip;

  // NOTE: ext_irq is intentionally NOT part of the master modport.  The
  // router never drives it; the SoC top drives the interface signal
  // directly.  Listing it as a master output makes synthesis tools tie the
  // undriven router-side port to GND, which then wins over the real driver
  // (multi-driven net) and kills all external interrupts on FPGA.
  modport master(
      output araddr, ar_commit,
      input rdata,

      output awaddr, wdata, wvalid,

      input meip, seip
  );

  modport slave(
      input ext_irq,

      input araddr, ar_commit,
      output rdata,

      input awaddr, wdata, wvalid,

      output meip, seip
  );
endinterface

/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on UNUSEDPARAM */
/* verilator lint_on UNDRIVEN */

`endif

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

// Internal memory transaction interface. Unlike AXI, a write request carries
// address and data together; protocol adapters own channel splitting.
interface mem_link_if #(
    parameter int XLEN = `RAPT_XLEN,
    parameter int ID_W = 4
);
  logic              rd_req_valid;
  logic              rd_req_ready;
  logic [  ID_W-1:0] rd_req_id;
  logic [  XLEN-1:0] rd_req_addr;
  logic [       2:0] rd_req_size;
  logic [       7:0] rd_req_len;
  logic [       1:0] rd_req_burst;

  logic              rd_rsp_valid;
  logic              rd_rsp_ready;
  logic [  ID_W-1:0] rd_rsp_id;
  logic [  XLEN-1:0] rd_rsp_data;
  logic              rd_rsp_last;
  logic              rd_rsp_error;

  logic                wr_req_valid;
  logic                wr_req_ready;
  logic [    ID_W-1:0] wr_req_id;
  logic [    XLEN-1:0] wr_req_addr;
  logic [         2:0] wr_req_size;
  logic [    XLEN-1:0] wr_req_data;
  logic [XLEN/8-1:0] wr_req_strb;

  logic              wr_rsp_valid;
  logic              wr_rsp_ready;
  logic [  ID_W-1:0] wr_rsp_id;
  logic              wr_rsp_error;

  modport master(
      output rd_req_valid, rd_req_id, rd_req_addr, rd_req_size, rd_req_len, rd_req_burst,
      input rd_req_ready,
      input rd_rsp_valid, rd_rsp_id, rd_rsp_data, rd_rsp_last, rd_rsp_error,
      output rd_rsp_ready,

      output wr_req_valid, wr_req_id, wr_req_addr, wr_req_size, wr_req_data, wr_req_strb,
      input wr_req_ready,
      input wr_rsp_valid, wr_rsp_id, wr_rsp_error,
      output wr_rsp_ready
  );

  modport slave(
      input rd_req_valid, rd_req_id, rd_req_addr, rd_req_size, rd_req_len, rd_req_burst,
      output rd_req_ready,
      output rd_rsp_valid, rd_rsp_id, rd_rsp_data, rd_rsp_last, rd_rsp_error,
      input rd_rsp_ready,

      input wr_req_valid, wr_req_id, wr_req_addr, wr_req_size, wr_req_data, wr_req_strb,
      output wr_req_ready,
      output wr_rsp_valid, wr_rsp_id, wr_rsp_error,
      input wr_rsp_ready
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

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
  logic [       3:0] arcache;
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

  logic [       3:0] awcache;
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
      output arburst, arcache, arsize, arlen, arid, araddr, arvalid,
      input arready,

      input rid, rlast, rdata, rresp, rvalid,
      output rready,

      output awburst, awcache, awsize, awlen, awid, awaddr, awvalid,
      input awready,

      output wlast, wdata, wstrb, wvalid,
      input wready,

      input bid, bresp, bvalid,
      output bready
  );

  modport slave(
      input arburst, arcache, arsize, arlen, arid, araddr, arvalid,
      output arready,

      output rid, rlast, rdata, rresp, rvalid,
      input rready,

      input awburst, awcache, awsize, awlen, awid, awaddr, awvalid,
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
  logic [       1:0] rd_req_pbmt;
  logic              rd_req_noallocate;

  logic              rd_rsp_valid;
  logic              rd_rsp_ready;
  logic [  ID_W-1:0] rd_rsp_id;
  logic [  XLEN-1:0] rd_rsp_data;
  logic              rd_rsp_last;
  logic              rd_rsp_error;

  logic                wr_req_valid;
  logic                wr_req_zero; // Generate a 64-byte INCR zero burst.
  logic                wr_req_ready;
  logic [    ID_W-1:0] wr_req_id;
  logic [    XLEN-1:0] wr_req_addr;
  logic [         2:0] wr_req_size;
  logic [         1:0] wr_req_pbmt;
  logic [    XLEN-1:0] wr_req_data;
  logic [XLEN/8-1:0] wr_req_strb;

  logic              wr_rsp_valid;
  logic              wr_rsp_ready;
  logic [  ID_W-1:0] wr_rsp_id;
  logic              wr_rsp_error;

  modport master(
      output rd_req_valid, rd_req_id, rd_req_addr, rd_req_size, rd_req_len, rd_req_burst, rd_req_pbmt, rd_req_noallocate,
      input rd_req_ready,
      input rd_rsp_valid, rd_rsp_id, rd_rsp_data, rd_rsp_last, rd_rsp_error,
      output rd_rsp_ready,

      output wr_req_valid, wr_req_zero, wr_req_id, wr_req_addr, wr_req_size, wr_req_pbmt, wr_req_data, wr_req_strb,
      input wr_req_ready,
      input wr_rsp_valid, wr_rsp_id, wr_rsp_error,
      output wr_rsp_ready
  );

  modport slave(
      input rd_req_valid, rd_req_id, rd_req_addr, rd_req_size, rd_req_len, rd_req_burst, rd_req_pbmt, rd_req_noallocate,
      output rd_req_ready,
      output rd_rsp_valid, rd_rsp_id, rd_rsp_data, rd_rsp_last, rd_rsp_error,
      input rd_rsp_ready,

      input wr_req_valid, wr_req_zero, wr_req_id, wr_req_addr, wr_req_size, wr_req_pbmt, wr_req_data, wr_req_strb,
      output wr_req_ready,
      output wr_rsp_valid, wr_rsp_id, wr_rsp_error,
      input wr_rsp_ready
  );
endinterface

// Client port of one hart's memory block towards the L2 subsystem, the only
// path from a core to memory and devices. The roles follow TileLink:
//   A  client -> L2  Get/Put requests (rd_req_*, wr_req_*); a write carries
//                    its address and data together, as in mem_link_if
//   D  L2 -> client  read data (rd_rsp_*) and write acknowledgements (wr_rsp_*)
//   B  L2 -> client  probes of L1D lines (probe_*)
//   C  client -> L2  probe responses (probe_release_*) and voluntary victim
//                    releases (release_*); release_ack completes a release
// Request IDs are the client's own (rapt_axi_ids_pkg); a multi-client L2
// extends them with the client index. Probe and release traffic is used only
// by an inclusive L2 (rapt_pkg::l2_link_config_t); a management-only L2 never
// probes and keeps release_ready low.
interface l2_client_if #(
    parameter int XLEN = `RAPT_XLEN,
    parameter int ID_W = 4
);
  // A: reads. The client resolves the PMA once and carries it with the request.
  logic              rd_req_valid;
  logic              rd_req_ready;
  logic [  ID_W-1:0] rd_req_id;
  logic [  XLEN-1:0] rd_req_addr;
  logic [       2:0] rd_req_size;
  logic [       7:0] rd_req_len;
  logic [       1:0] rd_req_burst;
  logic [       1:0] rd_req_pbmt;
  logic              rd_req_noallocate;
  logic              rd_req_cacheable;
  // D: read data.
  logic              rd_rsp_valid;
  logic              rd_rsp_ready;
  logic [  ID_W-1:0] rd_rsp_id;
  logic [  XLEN-1:0] rd_rsp_data;
  logic              rd_rsp_last;
  logic              rd_rsp_error;
  // A: writes.
  logic                wr_req_valid;
  logic                wr_req_zero;  // Generate a 64-byte INCR zero burst.
  logic                wr_req_ready;
  logic [    ID_W-1:0] wr_req_id;
  logic [    XLEN-1:0] wr_req_addr;
  logic [         2:0] wr_req_size;
  logic [         1:0] wr_req_pbmt;
  logic [    XLEN-1:0] wr_req_data;
  logic [XLEN/8-1:0] wr_req_strb;
  // D: write acknowledgements.
  logic              wr_rsp_valid;
  logic              wr_rsp_ready;
  logic [  ID_W-1:0] wr_rsp_id;
  logic              wr_rsp_error;
  // B: probes. probe_window marks cycles in which a probe may still start.
  logic              probe_valid;
  logic              probe_ready;
  logic [  XLEN-1:0] probe_addr;
  logic              probe_window;
  // C: probe responses carrying dirty data.
  logic              probe_release_valid;
  logic              probe_release_ready;
  logic [  XLEN-1:0] probe_release_addr;
  logic [  XLEN-1:0] probe_release_data;
  // C: voluntary releases, one XLEN beat at a time.
  logic              release_valid;
  logic              release_ready;
  logic [  XLEN-1:0] release_addr;
  logic [  XLEN-1:0] release_data;
  logic              release_has_data;
  logic              release_mask;
  logic              release_last;
  logic              release_ack;
  // Client state the L2 orders against: a victim write-back is on the A
  // channel, or a committed CBO.INVAL names a 64-byte block.
  logic              writeback_pending;
  logic              cbo_inval;
  logic [XLEN-1:6]   cbo_block;

  modport client(
      output rd_req_valid, rd_req_id, rd_req_addr, rd_req_size, rd_req_len, rd_req_burst,
      output rd_req_pbmt, rd_req_noallocate, rd_req_cacheable,
      input rd_req_ready,
      input rd_rsp_valid, rd_rsp_id, rd_rsp_data, rd_rsp_last, rd_rsp_error,
      output rd_rsp_ready,
      output wr_req_valid, wr_req_zero, wr_req_id, wr_req_addr, wr_req_size, wr_req_pbmt,
      output wr_req_data, wr_req_strb,
      input wr_req_ready,
      input wr_rsp_valid, wr_rsp_id, wr_rsp_error,
      output wr_rsp_ready,
      input probe_valid, probe_addr, probe_window,
      output probe_ready,
      output probe_release_valid, probe_release_addr, probe_release_data,
      input probe_release_ready,
      output release_valid, release_addr, release_data, release_has_data, release_mask,
      output release_last,
      input release_ready, release_ack,
      output writeback_pending, cbo_inval, cbo_block
  );

  modport manager(
      input rd_req_valid, rd_req_id, rd_req_addr, rd_req_size, rd_req_len, rd_req_burst,
      input rd_req_pbmt, rd_req_noallocate, rd_req_cacheable,
      output rd_req_ready,
      output rd_rsp_valid, rd_rsp_id, rd_rsp_data, rd_rsp_last, rd_rsp_error,
      input rd_rsp_ready,
      input wr_req_valid, wr_req_zero, wr_req_id, wr_req_addr, wr_req_size, wr_req_pbmt,
      input wr_req_data, wr_req_strb,
      output wr_req_ready,
      output wr_rsp_valid, wr_rsp_id, wr_rsp_error,
      input wr_rsp_ready,
      output probe_valid, probe_addr, probe_window,
      input probe_ready,
      input probe_release_valid, probe_release_addr, probe_release_data,
      output probe_release_ready,
      input release_valid, release_addr, release_data, release_has_data, release_mask,
      input release_last,
      output release_ready, release_ack,
      input writeback_pending, cbo_inval, cbo_block
  );
endinterface

interface clint_bus_if #(
    parameter int XLEN = `RAPT_XLEN
);
  logic [XLEN-1:0] araddr;
  logic [XLEN-1:0] rdata;

  logic [XLEN-1:0] awaddr;
  logic [XLEN-1:0] wdata;
  logic [XLEN/8-1:0] wstrb;
  logic            wvalid;

  logic            timer_int;
  logic            sw_int;
  logic [63:0]     mtime_value;

  modport master(
      output araddr,
      input rdata,
      output awaddr, wdata, wstrb, wvalid,
      input timer_int, sw_int, mtime_value
  );

  modport slave(
      input araddr,
      output rdata,
      input awaddr, wdata, wstrb, wvalid,
      output timer_int, sw_int, mtime_value
  );
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
  logic [XLEN/8-1:0] wstrb;
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

      output awaddr, wdata, wstrb, wvalid,

      input meip, seip
  );

  modport slave(
      input ext_irq,

      input araddr, ar_commit,
      output rdata,

      input awaddr, wdata, wstrb, wvalid,

      output meip, seip
  );
endinterface

/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on UNUSEDPARAM */
/* verilator lint_on UNDRIVEN */

`endif

`include "rapt.svh"
`include "rapt_soc.svh"
interface rapt_chip_if(input bit clock);
  localparam int X = `RAPT_XLEN;
  logic reset = 1;
  logic [3:0] arcache, awcache, arid, rid, awid, bid;
  logic [1:0] arburst, awburst, rresp, bresp;
  logic [2:0] arsize, awsize;
  logic [7:0] arlen, awlen;
  logic [X-1:0] araddr, awaddr, rdata, wdata;
  logic [X/8-1:0] wstrb;
  logic arvalid, arready, rvalid, rready, rlast;
  logic awvalid, awready, wvalid, wready, wlast, bvalid, bready;
  logic io_interrupt = 0;
  logic [`RAPT_PLIC_NDEV:1] ext_irq = 0;
  logic jtag_trst_n = 0, jtag_tms = 1, jtag_tdi = 0, jtag_tdo;
  logic external_write_valid = 0, external_write_pending = 0;
  logic [X-1:0] external_write_first = 0, external_write_last = 0;
endinterface

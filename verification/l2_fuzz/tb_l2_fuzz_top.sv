`include "rapt.svh"
`include "rapt_soc.svh"
`include "rapt_soc_if.svh"

// Flat-port wrapper around rapt_l2 for high-speed C++ randomized stress and
// golden-memory equivalence fuzzing in Verilator.
module tb_l2_fuzz_top #(
    parameter int XLEN = `RAPT_XLEN,
    parameter int ID_W = 4,
    parameter int L2_LEN = `RAPT_L2_LEN,
    parameter int L2_LINE_LEN = `RAPT_L2_LINE_LEN,
    parameter int L2_N_WAYS = `RAPT_L2_N_WAYS,
    parameter int PADDR_BITS = `RAPT_PADDR_BITS
) (
    input  logic clock,
    input  logic reset,
    // Inner AXI4 slave interface
    input  logic s_arvalid,
    output logic s_arready,
    input  logic [XLEN-1:0] s_araddr,
    input  logic [ID_W-1:0] s_arid,
    input  logic [7:0] s_arlen,
    input  logic [2:0] s_arsize,
    input  logic [1:0] s_arburst,
    input  logic [3:0] s_arcache,
    output logic s_rvalid,
    input  logic s_rready,
    output logic [XLEN-1:0] s_rdata,
    output logic [ID_W-1:0] s_rid,
    output logic [1:0] s_rresp,
    output logic s_rlast,
    input  logic s_awvalid,
    output logic s_awready,
    input  logic [XLEN-1:0] s_awaddr,
    input  logic [ID_W-1:0] s_awid,
    input  logic [7:0] s_awlen,
    input  logic [2:0] s_awsize,
    input  logic [1:0] s_awburst,
    input  logic [3:0] s_awcache,
    input  logic s_wvalid,
    output logic s_wready,
    input  logic [XLEN-1:0] s_wdata,
    input  logic [XLEN/8-1:0] s_wstrb,
    input  logic s_wlast,
    output logic s_bvalid,
    input  logic s_bready,
    output logic [ID_W-1:0] s_bid,
    output logic [1:0] s_bresp,
    // Outer AXI4 master interface
    output logic m_arvalid,
    input  logic m_arready,
    output logic [XLEN-1:0] m_araddr,
    output logic [ID_W-1:0] m_arid,
    output logic [7:0] m_arlen,
    output logic [2:0] m_arsize,
    output logic [1:0] m_arburst,
    output logic [3:0] m_arcache,
    input  logic m_rvalid,
    output logic m_rready,
    input  logic [XLEN-1:0] m_rdata,
    input  logic [ID_W-1:0] m_rid,
    input  logic [1:0] m_rresp,
    input  logic m_rlast,
    output logic m_awvalid,
    input  logic m_awready,
    output logic [XLEN-1:0] m_awaddr,
    output logic [ID_W-1:0] m_awid,
    output logic [7:0] m_awlen,
    output logic [2:0] m_awsize,
    output logic [1:0] m_awburst,
    output logic [3:0] m_awcache,
    output logic m_wvalid,
    input  logic m_wready,
    output logic [XLEN-1:0] m_wdata,
    output logic [XLEN/8-1:0] m_wstrb,
    output logic m_wlast,
    input  logic m_bvalid,
    output logic m_bready,
    input  logic [ID_W-1:0] m_bid,
    input  logic [1:0] m_bresp,
    // Coherence / CBO / Release ports
    input  logic cbo_inval_i,
    input  logic [XLEN-1:6] cbo_block_i,
    output logic probe_valid_o,
    output logic [XLEN-1:0] probe_addr_o,
    input  logic probe_ready_i,
    input  logic probe_release_valid_i,
    input  logic [XLEN-1:0] probe_release_addr_i,
    input  logic [XLEN-1:0] probe_release_data_i,
    output logic probe_release_ready_o,
    input  logic release_valid_i,
    input  logic [XLEN-1:0] release_addr_i,
    input  logic [XLEN-1:0] release_data_i,
    input  logic release_has_data_i,
    input  logic release_mask_i,
    input  logic release_last_i,
    output logic release_ready_o,
    output logic release_ack_o,
    input  logic l1d_writeback_pending_i,
    output logic probe_window_o,
    // Whitebox diagnostic telemetry
    output logic [4:0] dbg_rs,
    output logic [2:0] dbg_ws,
    output logic [3:0] dbg_cbo,
    output logic [2:0] dbg_rel,
    output logic dbg_ms_busy,
    output logic [7:0] dbg_ms_valid,
    output logic [ID_W-1:0] dbg_r_id,
    output logic [XLEN-1:0] dbg_r_addr,
    output logic dbg_boom,
    output logic dbg_dir_ready
);
  axi4_if #(
      .XLEN(XLEN),
      .ID_W(ID_W)
  ) axi_s ();
  axi4_if #(
      .XLEN(XLEN),
      .ID_W(ID_W)
  ) axi_m ();

  assign axi_s.arvalid = s_arvalid;
  assign s_arready = axi_s.arready;
  assign axi_s.araddr = s_araddr;
  assign axi_s.arid = s_arid;
  assign axi_s.arlen = s_arlen;
  assign axi_s.arsize = s_arsize;
  assign axi_s.arburst = s_arburst;
  assign axi_s.arcache = s_arcache;
  assign s_rvalid = axi_s.rvalid;
  assign axi_s.rready = s_rready;
  assign s_rdata = axi_s.rdata;
  assign s_rid = axi_s.rid;
  assign s_rresp = axi_s.rresp;
  assign s_rlast = axi_s.rlast;
  assign axi_s.awvalid = s_awvalid;
  assign s_awready = axi_s.awready;
  assign axi_s.awaddr = s_awaddr;
  assign axi_s.awid = s_awid;
  assign axi_s.awlen = s_awlen;
  assign axi_s.awsize = s_awsize;
  assign axi_s.awburst = s_awburst;
  assign axi_s.awcache = s_awcache;
  assign axi_s.wvalid = s_wvalid;
  assign s_wready = axi_s.wready;
  assign axi_s.wdata = s_wdata;
  assign axi_s.wstrb = s_wstrb;
  assign axi_s.wlast = s_wlast;
  assign s_bvalid = axi_s.bvalid;
  assign axi_s.bready = s_bready;
  assign s_bid = axi_s.bid;
  assign s_bresp = axi_s.bresp;

  assign m_arvalid = axi_m.arvalid;
  assign axi_m.arready = m_arready;
  assign m_araddr = axi_m.araddr;
  assign m_arid = axi_m.arid;
  assign m_arlen = axi_m.arlen;
  assign m_arsize = axi_m.arsize;
  assign m_arburst = axi_m.arburst;
  assign m_arcache = axi_m.arcache;
  assign axi_m.rvalid = m_rvalid;
  assign m_rready = axi_m.rready;
  assign axi_m.rdata = m_rdata;
  assign axi_m.rid = m_rid;
  assign axi_m.rresp = m_rresp;
  assign axi_m.rlast = m_rlast;
  assign m_awvalid = axi_m.awvalid;
  assign axi_m.awready = m_awready;
  assign m_awaddr = axi_m.awaddr;
  assign m_awid = axi_m.awid;
  assign m_awlen = axi_m.awlen;
  assign m_awsize = axi_m.awsize;
  assign m_awburst = axi_m.awburst;
  assign m_awcache = axi_m.awcache;
  assign m_wvalid = axi_m.wvalid;
  assign axi_m.wready = m_wready;
  assign m_wdata = axi_m.wdata;
  assign m_wstrb = axi_m.wstrb;
  assign m_wlast = axi_m.wlast;
  assign axi_m.bvalid = m_bvalid;
  assign m_bready = axi_m.bready;
  assign axi_m.bid = m_bid;
  assign axi_m.bresp = m_bresp;

  rapt_l2 #(
      .XLEN(XLEN),
      .ID_W(ID_W),
      .L2_LEN(L2_LEN),
      .L2_LINE_LEN(L2_LINE_LEN),
      .L2_N_WAYS(L2_N_WAYS),
      .PADDR_BITS(PADDR_BITS)
  ) dut (
      .sram_ctrl_i(rapt_pkg::SramCtrlReset),
      .clock,
      .reset,
      .cbo_inval_i,
      .cbo_block_i,
      .probe_valid_o,
      .probe_addr_o,
      .probe_ready_i,
      .probe_release_valid_i,
      .probe_release_addr_i,
      .probe_release_data_i,
      .probe_release_ready_o,
      .release_valid_i,
      .release_addr_i,
      .release_data_i,
      .release_has_data_i,
      .release_mask_i,
      .release_last_i,
      .release_ready_o,
      .release_ack_o,
      .l1d_writeback_pending_i,
      .probe_window_o,
      .axi_s,
      .axi_m
  );

  assign dbg_rs = dut.rs;
  assign dbg_ws = dut.ws;
  assign dbg_cbo = dut.cbo_state;
  assign dbg_rel = dut.release_state;
  assign dbg_ms_busy = dut.ms_busy;
  assign dbg_ms_valid = 8'(dut.ms_slot_valid);
  assign dbg_r_id = dut.r_id;
  assign dbg_r_addr = dut.r_addr;
  assign dbg_boom = dut.BoomBankedStore;
  assign dbg_dir_ready = dut.dir_ready;
endmodule

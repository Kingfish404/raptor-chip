// RVFI formal verification wrapper for Raptor Chip
//
// Provides unconstrained AXI4 responses to the rapt core, exposing only
// the RVFI output signals for riscv-formal checks.

module rvfi_wrapper (
    input clock,
    input reset,
    `RVFI_OUTPUTS
);
  // ----------------------------------------------------------------
  // Unconstrained AXI4 master responses (memory model abstracted away)
  // ----------------------------------------------------------------
  (* keep *)`rvformal_rand_reg        axi_arready;
  (* keep *)`rvformal_rand_reg [ 3:0] axi_rid;
  (* keep *)`rvformal_rand_reg        axi_rlast;
  (* keep *)`rvformal_rand_reg [31:0] axi_rdata;
  (* keep *)`rvformal_rand_reg [ 1:0] axi_rresp;
  (* keep *)`rvformal_rand_reg        axi_rvalid;
  (* keep *)`rvformal_rand_reg        axi_awready;
  (* keep *)`rvformal_rand_reg        axi_wready;
  (* keep *)`rvformal_rand_reg [ 3:0] axi_bid;
  (* keep *)`rvformal_rand_reg [ 1:0] axi_bresp;
  (* keep *)`rvformal_rand_reg        axi_bvalid;
  (* keep *)`rvformal_rand_reg        axi_interrupt;

  // AXI4 master output wires (from core, left unconnected for formal)
  (* keep *)wire               [ 1:0] m_arburst;
  (* keep *)wire               [ 2:0] m_arsize;
  (* keep *)wire               [ 7:0] m_arlen;
  (* keep *)wire               [ 3:0] m_arid;
  (* keep *)wire               [31:0] m_araddr;
  (* keep *)wire                      m_arvalid;
  (* keep *)wire                      m_rready;

  (* keep *)wire               [ 1:0] m_awburst;
  (* keep *)wire               [ 2:0] m_awsize;
  (* keep *)wire               [ 7:0] m_awlen;
  (* keep *)wire               [ 3:0] m_awid;
  (* keep *)wire               [31:0] m_awaddr;
  (* keep *)wire                      m_awvalid;

  (* keep *)wire                      m_wlast;
  (* keep *)wire               [31:0] m_wdata;
  (* keep *)wire               [ 3:0] m_wstrb;
  (* keep *)wire                      m_wvalid;
  (* keep *)wire                      m_bready;

  rapt uut (
      .clock(clock),
      .reset(reset),

      // AXI4 master — AR channel
      .io_master_arburst(m_arburst),
      .io_master_arsize (m_arsize),
      .io_master_arlen  (m_arlen),
      .io_master_arid   (m_arid),
      .io_master_araddr (m_araddr),
      .io_master_arvalid(m_arvalid),
      .io_master_arready(axi_arready),

      // AXI4 master — R channel
      .io_master_rid   (axi_rid),
      .io_master_rlast (axi_rlast),
      .io_master_rdata (axi_rdata),
      .io_master_rresp (axi_rresp),
      .io_master_rvalid(axi_rvalid),
      .io_master_rready(m_rready),

      // AXI4 master — AW channel
      .io_master_awburst(m_awburst),
      .io_master_awsize (m_awsize),
      .io_master_awlen  (m_awlen),
      .io_master_awid   (m_awid),
      .io_master_awaddr (m_awaddr),
      .io_master_awvalid(m_awvalid),
      .io_master_awready(axi_awready),

      // AXI4 master — W channel
      .io_master_wlast (m_wlast),
      .io_master_wdata (m_wdata),
      .io_master_wstrb (m_wstrb),
      .io_master_wvalid(m_wvalid),
      .io_master_wready(axi_wready),

      // AXI4 master — B channel
      .io_master_bid   (axi_bid),
      .io_master_bresp (axi_bresp),
      .io_master_bvalid(axi_bvalid),
      .io_master_bready(m_bready),

      // Interrupt
      .io_interrupt(axi_interrupt),
      .ext_irq_i   ('0),

      // RVFI
      .rvfi_valid    (rvfi_valid),
      .rvfi_order    (rvfi_order),
      .rvfi_insn     (rvfi_insn),
      .rvfi_trap     (rvfi_trap),
      .rvfi_halt     (rvfi_halt),
      .rvfi_intr     (rvfi_intr),
      .rvfi_mode     (rvfi_mode),
      .rvfi_ixl      (rvfi_ixl),
      .rvfi_rs1_addr (rvfi_rs1_addr),
      .rvfi_rs2_addr (rvfi_rs2_addr),
      .rvfi_rs1_rdata(rvfi_rs1_rdata),
      .rvfi_rs2_rdata(rvfi_rs2_rdata),
      .rvfi_rd_addr  (rvfi_rd_addr),
      .rvfi_rd_wdata (rvfi_rd_wdata),
      .rvfi_pc_rdata (rvfi_pc_rdata),
      .rvfi_pc_wdata (rvfi_pc_wdata),
      .rvfi_mem_addr (rvfi_mem_addr),
      .rvfi_mem_rmask(rvfi_mem_rmask),
      .rvfi_mem_wmask(rvfi_mem_wmask),
      .rvfi_mem_rdata(rvfi_mem_rdata),
      .rvfi_mem_wdata(rvfi_mem_wdata)
  );

endmodule

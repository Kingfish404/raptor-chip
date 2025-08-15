`include "ysyx.svh"
`include "ysyx_if.svh"
`include "ysyx_soc.svh"
`include "ysyx_dpi_c.svh"

module ysyx #(
    parameter bit [7:0] XLEN = `YSYX_XLEN
) (
    input clock,

`ifdef YSYX_USE_SLAVE
    // AXI4 Slave
    // verilator lint_off UNDRIVEN
    // verilator lint_off UNUSEDSIGNAL
    input  [     1:0] io_slave_arburst,
    input  [     2:0] io_slave_arsize,
    input  [     7:0] io_slave_arlen,
    input  [     3:0] io_slave_arid,
    input  [XLEN-1:0] io_slave_araddr,
    input             io_slave_arvalid,
    output            io_slave_arready,

    output [     3:0] io_slave_rid,
    output            io_slave_rlast,
    output [XLEN-1:0] io_slave_rdata,
    output [     1:0] io_slave_rresp,
    output            io_slave_rvalid,
    input             io_slave_rready,

    input  [     1:0] io_slave_awburst,
    input  [     2:0] io_slave_awsize,
    input  [     7:0] io_slave_awlen,
    input  [     3:0] io_slave_awid,
    input  [XLEN-1:0] io_slave_awaddr,
    input             io_slave_awvalid,
    output            io_slave_awready,

    input             io_slave_wlast,
    input  [XLEN-1:0] io_slave_wdata,
    input  [     3:0] io_slave_wstrb,
    input             io_slave_wvalid,
    output            io_slave_wready,

    output [3:0] io_slave_bid,
    output [1:0] io_slave_bresp,
    output       io_slave_bvalid,
    input        io_slave_bready,
    // verilator lint_on UNDRIVEN
    // verilator lint_on UNUSEDSIGNAL
`endif

    // AXI4 Master
    output [     1:0] io_master_arburst,
    output [     2:0] io_master_arsize,
    output [     7:0] io_master_arlen,
    output [     3:0] io_master_arid,
    output [XLEN-1:0] io_master_araddr,
    output            io_master_arvalid,
    input             io_master_arready,

    input  [     3:0] io_master_rid,
    input             io_master_rlast,
    input  [XLEN-1:0] io_master_rdata,
    input  [     1:0] io_master_rresp,
    input             io_master_rvalid,
    output            io_master_rready,

    output [     1:0] io_master_awburst,
    output [     2:0] io_master_awsize,
    output [     7:0] io_master_awlen,
    output [     3:0] io_master_awid,
    output [XLEN-1:0] io_master_awaddr,
    output            io_master_awvalid,
    input             io_master_awready,

    output            io_master_wlast,
    output [XLEN-1:0] io_master_wdata,
    output [     3:0] io_master_wstrb,
    output            io_master_wvalid,
    input             io_master_wready,

    input  [3:0] io_master_bid,
    input  [1:0] io_master_bresp,
    input        io_master_bvalid,
    output       io_master_bready,

    // verilator lint_off UNDRIVEN
    // verilator lint_off UNUSEDSIGNAL
    input io_interrupt,
    // verilator lint_on UNDRIVEN
    // verilator lint_on UNUSEDSIGNAL

    input reset
);
  // L1I Cache
  l1i_bus_if l1i_bus ();

  // IFU stage
  ifu_idu_if ifu_idu ();  // Fetch => Decode

  ifu_bpu_if ifu_bpu ();
  ifu_l1i_if ifu_l1i ();

  // IDU stage
  idu_rnu_if idu_rnu ();  // Decode => Re-naming

  // RNU stage
  rnu_rou_if rnu_rou ();  // Re-naming => Issue

  // ROU stage
  rou_exu_if rou_exu ();  // Issue => Execute
  rou_lsu_if rou_lsu ();  // Commit
  rou_cmu_if rou_cmu ();  // Commit

  rou_csr_if rou_csr ();

  // EXU stage
  exu_rou_if exu_rou ();  // Execute & Writeback => Commit

  exu_prf_if exu_prf ();
  exu_ioq_rou_if exu_ioq_rou ();
  exu_csr_if exu_csr ();
  exu_lsu_if exu_lsu ();

  // CMU
  cmu_pipe_if cmu_bcast ();  // Difftest & Debug

  // LSU
  lsu_l1d_if lsu_l1d ();

  // L1D Cache
  l1d_bus_if l1d_bus ();

  ysyx_bpu bpu (
      .clock(clock),

      .cmu_bcast(cmu_bcast),

      .ifu_bpu(ifu_bpu),

      .reset(reset)
  );

  // IFU (Instruction Fetch Unit)
  ysyx_ifu ifu (
      .clock(clock),

      .cmu_bcast(cmu_bcast),

      .ifu_bpu(ifu_bpu),
      .ifu_l1i(ifu_l1i),
      .ifu_idu(ifu_idu),

      .reset(reset)
  );

  ysyx_l1i l1i_cache (
      .clock(clock),

      .ifu_l1i(ifu_l1i),
      .l1i_bus(l1i_bus),

      .reset(reset)
  );

  // IDU (Instruction Decode Unit)
  ysyx_idu idu (
      .clock(clock),

      .cmu_bcast(cmu_bcast),

      .ifu_idu(ifu_idu),
      .idu_rnu(idu_rnu),

      .reset(reset)
  );

  // RNU (Re-naming Unit)
  ysyx_rnu rnu (
      .clock(clock),

      // write-back
      .exu_rou(exu_rou),
      .exu_ioq_rou(exu_ioq_rou),

      // commit
      .rou_cmu  (rou_cmu),
      .cmu_bcast(cmu_bcast),

      .idu_rnu(idu_rnu),
      .rnu_rou(rnu_rou),

      .exu_prf(exu_prf),

      .reset(reset)
  );

  // ROU (Re-Order Unit)
  ysyx_rou rou (
      .clock(clock),

      .rnu_rou(rnu_rou),

      // issue
      .exu_prf(exu_prf),
      .rou_exu(rou_exu),

      .exu_rou(exu_rou),
      .exu_ioq_rou(exu_ioq_rou),

      .rou_csr(rou_csr),

      .rou_lsu(rou_lsu),
      .rou_cmu(rou_cmu),

      .reset(reset)
  );

  // EXU (EXecution Unit)
  ysyx_exu exu (
      .clock(clock),

      .cmu_bcast(cmu_bcast),

      .rou_exu(rou_exu),

      .exu_rou(exu_rou),
      .exu_ioq_rou(exu_ioq_rou),

      .exu_lsu(exu_lsu),
      .exu_csr(exu_csr),

      .reset(reset)
  );

  // CMU (ComMit Unit)
  ysyx_cmu cmu (
      .clock(clock),

      .rou_cmu  (rou_cmu),
      .cmu_bcast(cmu_bcast),

      .reset(reset)
  );

  ysyx_csr csrs (
      .clock(clock),

      .rou_csr(rou_csr),
      .exu_csr(exu_csr),

      .reset(reset)
  );

  // LSU (Load/Store Unit)
  ysyx_lsu lsu (
      .clock(clock),

      .cmu_bcast(cmu_bcast),

      .lsu_l1d(lsu_l1d),

      .exu_lsu(exu_lsu),
      .exu_ioq_rou(exu_ioq_rou),
      .rou_lsu(rou_lsu),

      .l1d_bus(l1d_bus),

      .reset(reset)
  );

  ysyx_l1d l1d_cache (
      .clock(clock),

      .cmu_bcast(cmu_bcast),

      .lsu_l1d(lsu_l1d),
      .l1d_bus(l1d_bus),

      .reset(reset)
  );

  ysyx_bus bus (
      .clock(clock),

      .axi_arburst(io_master_arburst),
      .axi_arsize(io_master_arsize),
      .axi_arlen(io_master_arlen),
      .axi_arid(io_master_arid),
      .axi_araddr(io_master_araddr),
      .axi_arvalid(io_master_arvalid),
      .axi_arready(io_master_arready),

      .axi_rid(io_master_rid),
      .axi_rlast(io_master_rlast),
      .axi_rdata(io_master_rdata),
      .axi_rresp(io_master_rresp),
      .axi_rvalid(io_master_rvalid),
      .axi_rready(io_master_rready),

      .axi_awburst(io_master_awburst),
      .axi_awsize(io_master_awsize),
      .axi_awlen(io_master_awlen),
      .axi_awid(io_master_awid),
      .axi_awaddr(io_master_awaddr),
      .axi_awvalid(io_master_awvalid),
      .axi_awready(io_master_awready),

      .axi_wlast (io_master_wlast),
      .axi_wdata (io_master_wdata),
      .axi_wstrb (io_master_wstrb),
      .axi_wvalid(io_master_wvalid),
      .axi_wready(io_master_wready),

      .axi_bid(io_master_bid),
      .axi_bresp(io_master_bresp),
      .axi_bvalid(io_master_bvalid),
      .axi_bready(io_master_bready),

      .l1i_bus(l1i_bus),
      .l1d_bus(l1d_bus),

      .reset(reset)
  );

endmodule

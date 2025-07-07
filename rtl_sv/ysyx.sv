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
    input [1:0] io_slave_arburst,
    input [2:0] io_slave_arsize,
    input [7:0] io_slave_arlen,
    input [3:0] io_slave_arid,
    input [XLEN-1:0] io_slave_araddr,
    input io_slave_arvalid,
    output logic io_slave_arready,

    output logic [3:0] io_slave_rid,
    output logic io_slave_rlast,
    output logic [XLEN-1:0] io_slave_rdata,
    output logic [1:0] io_slave_rresp,
    output logic io_slave_rvalid,
    input io_slave_rready,

    input [1:0] io_slave_awburst,
    input [2:0] io_slave_awsize,
    input [7:0] io_slave_awlen,
    input [3:0] io_slave_awid,
    input [XLEN-1:0] io_slave_awaddr,
    input io_slave_awvalid,
    output logic io_slave_awready,

    input io_slave_wlast,
    input [XLEN-1:0] io_slave_wdata,
    input [3:0] io_slave_wstrb,
    input io_slave_wvalid,
    output logic io_slave_wready,

    output logic [3:0] io_slave_bid,
    output logic [1:0] io_slave_bresp,
    output logic io_slave_bvalid,
    input io_slave_bready,
    // verilator lint_on UNDRIVEN
    // verilator lint_on UNUSEDSIGNAL
`endif

    // AXI4 Master
    output [1:0] io_master_arburst,
    output [2:0] io_master_arsize,
    output [7:0] io_master_arlen,
    output [3:0] io_master_arid,
    output [XLEN-1:0] io_master_araddr,
    output io_master_arvalid,
    input logic io_master_arready,

    input logic [3:0] io_master_rid,
    input logic io_master_rlast,
    input logic [XLEN-1:0] io_master_rdata,
    input logic [1:0] io_master_rresp,
    input logic io_master_rvalid,
    output io_master_rready,

    output [1:0] io_master_awburst,
    output [2:0] io_master_awsize,
    output [7:0] io_master_awlen,
    output [3:0] io_master_awid,
    output [XLEN-1:0] io_master_awaddr,
    output io_master_awvalid,
    input logic io_master_awready,

    output io_master_wlast,
    output [XLEN-1:0] io_master_wdata,
    output [3:0] io_master_wstrb,
    output io_master_wvalid,
    input logic io_master_wready,

    input logic [3:0] io_master_bid,
    input logic [1:0] io_master_bresp,
    input logic io_master_bvalid,
    output io_master_bready,

    // verilator lint_off UNDRIVEN
    // verilator lint_off UNUSEDSIGNAL
    input io_interrupt,
    // verilator lint_on UNDRIVEN
    // verilator lint_on UNUSEDSIGNAL

    input reset
);
  // IFU
  ifu_idu_if ifu_idu ();
  ifu_bus_if ifu_bus ();
  logic ifu_valid;

  // IDU
  idu_pipe_if idu_rou ();
  logic idu_valid, idu_ready;

  // ROU
  idu_pipe_if rou_exu ();
  rou_lsu_if rou_lsu ();
  rou_reg_if rou_reg ();

  rou_csr_if rou_csr ();
  rou_wbu_if rou_wbu ();
  logic rou_valid, rou_ready;

  // EXU
  exu_rou_if exu_rou ();
  exu_ioq_rou_if exu_ioq_rou ();
  exu_csr_if exu_csr ();
  exu_lsu_if exu_lsu ();
  logic exu_valid, exu_ready;

  // WBU
  wbu_pipe_if wbu_bcast ();
  logic wbu_valid;

  // LSU
  lsu_bus_if lsu_bus ();
  logic lsu_sq_ready;

  // IFU (Instruction Fetch Unit)
  ysyx_ifu ifu (
      .clock(clock),

      .flush_pipe(wbu_bcast.flush_pipe),
      .fence_time(wbu_bcast.fence_time),

      // <= wbu
      .wbu_bcast(wbu_bcast),

      .ifu_idu(ifu_idu),
      .ifu_bus(ifu_bus),

      .fence_i(wbu_bcast.fence_i),

      .prev_valid(wbu_valid),
      .next_ready(idu_ready),
      .out_valid (ifu_valid),

      .reset(reset)
  );

  // IDU (Instruction Decode Unit)
  ysyx_idu idu (
      .clock(clock),

      .flush_pipe(wbu_bcast.flush_pipe),

      .ifu_idu(ifu_idu),
      .idu_rou(idu_rou),

      .prev_valid(ifu_valid),
      .next_ready(rou_ready),
      .out_valid (idu_valid),
      .out_ready (idu_ready),

      .reset(reset)
  );

  // ROU (Re-Order Unit)
  ysyx_rou rou (
      .clock(clock),

      .flush_pipe(wbu_bcast.flush_pipe),
      .fence_time(wbu_bcast.fence_time),

      .idu_rou(idu_rou),
      .rou_exu(rou_exu),

      .exu_rou(exu_rou),
      .exu_ioq_rou(exu_ioq_rou),

      .rou_reg(rou_reg),
      .rou_csr(rou_csr),

      .rou_lsu(rou_lsu),
      .rou_wbu(rou_wbu),

      .sq_ready(lsu_sq_ready),

      .prev_valid(idu_valid),
      .next_ready(exu_ready),
      .out_valid (rou_valid),
      .out_ready (rou_ready),

      .reset(reset)
  );

  // EXU (EXecution Unit)
  ysyx_exu exu (
      .clock(clock),

      // <= idu
      .rou_exu(rou_exu),
      .flush_pipe(wbu_bcast.flush_pipe),

      .exu_rou(exu_rou),
      .exu_ioq_rou(exu_ioq_rou),

      .exu_lsu(exu_lsu),
      .exu_csr(exu_csr),

      .prev_valid(rou_valid),
      .out_valid (exu_valid),
      .out_ready (exu_ready),

      .reset(reset)
  );

  // WBU (Write Back Unit)
  ysyx_wbu wbu (
      .clock(clock),

      .rou_wbu  (rou_wbu),
      .wbu_bcast(wbu_bcast),

      .prev_valid(rou_wbu.valid),
      .out_valid (wbu_valid),

      .reset(reset)
  );

  ysyx_reg regs (
      .clock(clock),

      .write_en(rou_wbu.valid && wbu_bcast.flush_pipe == 0),
      .waddr(rou_wbu.rd),
      .wdata(rou_wbu.wdata),

      .rou_reg(rou_reg),

      .reset(reset)
  );

  ysyx_csr csrs (
      .clock(clock),

      .wen(rou_csr.csr_wen),
      .valid(rou_csr.valid),
      .ecall(rou_csr.ecall),
      .mret(rou_csr.mret),
      .ebreak(rou_csr.ebreak),

      .trap(rou_csr.trap),
      .tval(rou_csr.tval),

      .cause(rou_csr.cause),

      .waddr(rou_csr.csr_addr),
      .wdata(rou_csr.csr_wdata),
      .pc(rou_csr.pc),

      .exu_csr(exu_csr),

      .reset(reset)
  );

  // LSU (Load/Store Unit)
  ysyx_lsu lsu (
      .clock(clock),

      .flush_pipe(wbu_bcast.flush_pipe),
      .fence_time(wbu_bcast.fence_time),

      .exu_lsu(exu_lsu),
      .exu_ioq_rou(exu_ioq_rou),
      .rou_lsu(rou_lsu),
      .out_sq_ready(lsu_sq_ready),

      .lsu_bus(lsu_bus),

      .reset(reset)
  );

  ysyx_bus bus (
      .clock(clock),

      .flush_pipe(wbu_bcast.flush_pipe),

      .io_master_arburst(io_master_arburst),
      .io_master_arsize(io_master_arsize),
      .io_master_arlen(io_master_arlen),
      .io_master_arid(io_master_arid),
      .io_master_araddr(io_master_araddr),
      .io_master_arvalid(io_master_arvalid),
      .io_master_arready(io_master_arready),

      .io_master_rid(io_master_rid),
      .io_master_rlast(io_master_rlast),
      .io_master_rdata(io_master_rdata),
      .io_master_rresp(io_master_rresp),
      .io_master_rvalid(io_master_rvalid),
      .io_master_rready(io_master_rready),

      .io_master_awburst(io_master_awburst),
      .io_master_awsize(io_master_awsize),
      .io_master_awlen(io_master_awlen),
      .io_master_awid(io_master_awid),
      .io_master_awaddr(io_master_awaddr),
      .io_master_awvalid(io_master_awvalid),
      .io_master_awready(io_master_awready),

      .io_master_wlast (io_master_wlast),
      .io_master_wdata (io_master_wdata),
      .io_master_wstrb (io_master_wstrb),
      .io_master_wvalid(io_master_wvalid),
      .io_master_wready(io_master_wready),

      .io_master_bid(io_master_bid),
      .io_master_bresp(io_master_bresp),
      .io_master_bvalid(io_master_bvalid),
      .io_master_bready(io_master_bready),

      .ifu_bus(ifu_bus),
      .lsu_bus(lsu_bus),

      .reset(reset)
  );

endmodule

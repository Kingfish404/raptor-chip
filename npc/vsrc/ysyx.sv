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
  // IFU out
  logic [31:0] ifu_inst;
  logic [XLEN-1:0] ifu_pc;
  logic [XLEN-1:0] ifu_pnpc;
  logic ifu_valid, ifu_ready;
  // IFU out bus
  logic [XLEN-1:0] ifu_araddr;
  logic ifu_arvalid, ifu_bus_lock;

  // IDU out
  idu_pipe_if idu_iqu ();
  logic idu_valid, idu_ready;

  // IQU out
  idu_pipe_if iqu_exu_if ();
  exu_pipe_if iqu_wbu_if ();
  exu_pipe_if iqu_exu_cm ();
  iqu_lsu_if iqu_lsu ();
  logic iqu_valid, iqu_ready;
  logic [4:0] iqu_rs1, iqu_rs2;
  logic flush_pipeline;
  logic fence_time;

  // EXU out
  exu_pipe_if exu_wb_if ();
  logic exu_ready;
  logic lsu_sq_ready;
  // EXU out lsu
  logic exu_ren;
  logic [XLEN-1:0] exu_raddr;
  logic [4:0] exu_ralu;

  // WBU out
  wbu_pipe_if wbu_if ();
  logic wbu_valid;

  // Reg out
  logic [XLEN-1:0] reg_rdata1, reg_rdata2;

  // lsu out
  logic [XLEN-1:0] lsu_rdata;
  logic lsu_exu_rvalid;
  lsu_bus_if lsu_bus ();

  // bus out
  logic bus_ifu_rvalid;
  logic [XLEN-1:0] bus_ifu_rdata;
  logic bus_ifu_ready;

  // IFU (Instruction Fetch Unit)
  ysyx_ifu ifu (
      .clock(clock),

      // <= wbu
      .wbu_if(wbu_if),

      .out_inst(ifu_inst),
      .out_pc(ifu_pc),
      .out_pnpc(ifu_pnpc),
      .flush_pipeline(flush_pipeline),
      .fence_time(fence_time),

      .bus_ifu_ready(bus_ifu_ready),
      .out_ifu_lock(ifu_bus_lock),
      .out_ifu_araddr(ifu_araddr),
      .out_ifu_arvalid(ifu_arvalid),
      .ifu_rdata(bus_ifu_rdata),
      .ifu_rvalid(bus_ifu_rvalid),

      .fence_i(iqu_wbu_if.fence_i),

      .prev_valid(wbu_valid),
      .next_ready(idu_ready),
      .out_valid (ifu_valid),
      .out_ready (ifu_ready),

      .reset(reset)
  );

  // IDU (Instruction Decode Unit)
  ysyx_idu idu (
      .clock(clock),

      .inst(ifu_inst),
      .pc(ifu_pc),
      .pnpc(ifu_pnpc),
      .idu_if(idu_iqu),

      .prev_valid(ifu_valid),
      .next_ready(iqu_ready),
      .out_valid (idu_valid),
      .out_ready (idu_ready),

      .reset(reset || flush_pipeline)
  );

  // IQU (Instruction Queue Unit)
  ysyx_iqu iqu (
      .clock(clock),

      .idu_if(idu_iqu),
      .iqu_exu_if(iqu_exu_if),

      .exu_wb_if(exu_wb_if),

      .iqu_wbu_if(iqu_wbu_if),

      .out_rs1(iqu_rs1),
      .out_rs2(iqu_rs2),
      .rdata1 (reg_rdata1),
      .rdata2 (reg_rdata2),

      // => exu (commit)
      .iqu_cm_if(iqu_exu_cm),
      .iqu_lsu_o(iqu_lsu),

      .out_flush_pipeline(flush_pipeline),
      .out_fence_time(fence_time),

      .prev_valid(idu_valid),
      .next_ready(exu_ready),
      .sq_ready  (lsu_sq_ready),
      .out_valid (iqu_valid),
      .out_ready (iqu_ready),

      .reset(reset || flush_pipeline)
  );

  // EXU (EXecution Unit)
  ysyx_exu exu (
      .clock(clock),

      // <= idu
      .idu_if(iqu_exu_if),
      .flush_pipeline(flush_pipeline),

      // => lsu
      .out_ren(exu_ren),
      .out_raddr(exu_raddr),
      .out_ralu(exu_ralu),
      // <= lsu
      .lsu_rdata(lsu_rdata),
      .lsu_exu_rvalid(lsu_exu_rvalid),

      // => iqu & (wbu)
      .exu_wb_if(exu_wb_if),

      // <= iqu
      .iqu_cm_if(iqu_exu_cm),

      .prev_valid(iqu_valid),
      .out_ready (exu_ready),

      .reset(reset)
  );

  // WBU (Write Back Unit)
  ysyx_wbu wbu (
      .clock(clock),

      .inst(iqu_wbu_if.inst),
      .pc(iqu_wbu_if.pc),
      .ebreak(iqu_wbu_if.ebreak),

      .npc_wdata(iqu_wbu_if.npc),
      .jen(iqu_wbu_if.jen),
      .ben(iqu_wbu_if.ben),
      .sys_retire(iqu_wbu_if.sys_retire),

      .wbu_if(wbu_if),

      .prev_valid(iqu_wbu_if.valid),
      .out_valid (wbu_valid),

      .reset(reset)
  );

  ysyx_reg regs (
      .clock(clock),

      .write_en(iqu_wbu_if.valid && flush_pipeline == 0),
      .waddr(iqu_wbu_if.rd),
      .wdata(iqu_wbu_if.result),

      .s1addr  (iqu_rs1),
      .s2addr  (iqu_rs2),
      .out_src1(reg_rdata1),
      .out_src2(reg_rdata2),

      .reset(reset)
  );

  // LSU (Load/Store Unit)
  ysyx_lsu lsu (
      .clock(clock),

      .flush_pipeline(flush_pipeline),
      .fence_time(fence_time),

      // from exu
      .ren(exu_ren),
      .raddr(exu_raddr),
      .ralu(exu_ralu),
      // to exu
      .out_rdata(lsu_rdata),
      .out_rvalid(lsu_exu_rvalid),

      .iqu_lsu_i(iqu_lsu),
      .out_sq_ready(lsu_sq_ready),

      .lsu_bus(lsu_bus),

      .reset(reset)
  );

  ysyx_bus bus (
      .clock(clock),

      .flush_pipeline(flush_pipeline),

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

      // ifu
      .out_bus_ifu_ready(bus_ifu_ready),
      .ifu_araddr(ifu_araddr),
      .ifu_arvalid(ifu_arvalid),
      .ifu_lock(ifu_bus_lock),
      .ifu_ready(ifu_ready),
      .out_ifu_rdata(bus_ifu_rdata),
      .out_ifu_rvalid(bus_ifu_rvalid),

      .lsu_bus(lsu_bus),

      .reset(reset)
  );

endmodule

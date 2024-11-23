`include "ysyx.svh"
`include "ysyx_if.svh"
`include "ysyx_soc.svh"
`include "ysyx_dpi_c.svh"

module ysyx (
    input clock,

    // verilator lint_off UNDRIVEN
    // AXI4 Slave
    input [1:0] io_slave_arburst,
    input [2:0] io_slave_arsize,
    input [7:0] io_slave_arlen,
    input [3:0] io_slave_arid,
    input [XLEN-1:0] io_slave_araddr,
    input io_slave_arvalid,
    output reg io_slave_arready,

    output reg [3:0] io_slave_rid,
    output reg io_slave_rlast,
    output reg [XLEN-1:0] io_slave_rdata,
    output reg [1:0] io_slave_rresp,
    output reg io_slave_rvalid,
    input io_slave_rready,

    input [1:0] io_slave_awburst,
    input [2:0] io_slave_awsize,
    input [7:0] io_slave_awlen,
    input [3:0] io_slave_awid,
    input [XLEN-1:0] io_slave_awaddr,
    input io_slave_awvalid,
    output reg io_slave_awready,

    input io_slave_wlast,
    input [XLEN-1:0] io_slave_wdata,
    input [3:0] io_slave_wstrb,
    input io_slave_wvalid,
    output reg io_slave_wready,

    output reg [3:0] io_slave_bid,
    output reg [1:0] io_slave_bresp,
    output reg io_slave_bvalid,
    input io_slave_bready,
    // verilator lint_on UNDRIVEN

    // AXI4 Master
    output [1:0] io_master_arburst,
    output [2:0] io_master_arsize,
    output [7:0] io_master_arlen,
    output [3:0] io_master_arid,
    output [XLEN-1:0] io_master_araddr,
    output io_master_arvalid,
    input reg io_master_arready,

    input reg [3:0] io_master_rid,
    input reg io_master_rlast,
    input reg [XLEN-1:0] io_master_rdata,
    input reg [1:0] io_master_rresp,
    input reg io_master_rvalid,
    output io_master_rready,

    output [1:0] io_master_awburst,
    output [2:0] io_master_awsize,
    output [7:0] io_master_awlen,
    output [3:0] io_master_awid,
    output [XLEN-1:0] io_master_awaddr,
    output io_master_awvalid,
    input reg io_master_awready,

    output io_master_wlast,
    output [XLEN-1:0] io_master_wdata,
    output [3:0] io_master_wstrb,
    output io_master_wvalid,
    input reg io_master_wready,

    input reg [3:0] io_master_bid,
    input reg [1:0] io_master_bresp,
    input reg io_master_bvalid,
    output io_master_bready,

    input io_interrupt,

    input reset
);
  parameter bit [7:0] XLEN = `YSYX_XLEN;
  parameter bit [7:0] REG_ADDR_W = `YSYX_REG_LEN;

  // IFU out
  wire [31:0] ifu_inst;
  wire [XLEN-1:0] ifu_pc;
  wire ifu_speculation;
  wire flush_pipeline;
  wire ifu_valid, ifu_ready;
  // IFU out bus
  wire [XLEN-1:0] ifu_araddr;
  wire ifu_arvalid, ifu_required;

  // IDU out
  idu_pipe_if idu_if ();
  wire idu_valid, idu_ready;
  wire [REG_ADDR_W-1:0] idu_rs1, idu_rs2;

  // EXU out
  wire [31:0] exu_inst, exu_pc;
  wire [XLEN-1:0] exu_reg_wdata;
  wire [XLEN-1:0] exu_npc_wdata;
  wire exu_branch_change, exu_branch_retire, exu_load_retire;
  wire exu_ebreak;
  wire [REG_ADDR_W-1:0] exu_rd;
  wire exu_valid, exu_ready;
  // EXU out lsu
  wire exu_ren, exu_wen;
  wire [XLEN-1:0] exu_rwaddr;
  wire exu_lsu_avalid;
  wire [4:0] exu_alu_op;
  wire [XLEN-1:0] exu_lsu_wdata;

  // WBU out
  wire [31:0] wbu_pc;
  wire wbu_valid, wbu_ready;
  wire [XLEN-1:0] wbu_npc;
  wire wbu_pc_change, wbu_pc_retire;

  // reg out
  wire [`YSYX_REG_NUM-1:0] reg_rf_table;
  wire [XLEN-1:0] reg_rdata1, reg_rdata2;

  // lsu out
  wire [XLEN-1:0] lsu_rdata;
  wire lsu_exu_rvalid;
  wire lsu_exu_wready;
  // lsu out load
  wire [XLEN-1:0] lsu_araddr;
  wire lsu_arvalid;
  wire [7:0] lsu_rstrb;
  // lsu out store
  wire [XLEN-1:0] lsu_awaddr;
  wire lsu_awvalid;
  wire [XLEN-1:0] lsu_wdata;
  wire [7:0] lsu_wstrb;
  wire lsu_wvalid;

  // bus out
  wire [XLEN-1:0] bus_ifu_rdata;
  wire bus_ifu_rvalid;
  wire [XLEN-1:0] bus_lsu_rdata;
  wire bus_lsu_rvalid;
  wire bus_lsu_wready;

  //------------------------------------------------------------------------------
  // RISC-V Processor Core
  //------------------------------------------------------------------------------
  // has the following (conceptual) stages:
  //   if - Instruction fetch
  //   id - Instruction Decode
  //   ex - Execution
  //   wb - Write Back
  //------------------------------------------------------------------------------
  // [frontend: [if => id]] => [backend: [ex => wb]]

  // IFU (Instruction Fetch Unit)
  ysyx_ifu ifu (
      .clock(clock),

      .load_retire(exu_load_retire),

      .npc(wbu_npc),
      .pc_change(wbu_pc_change),
      .pc_retire(wbu_pc_retire),

      .out_inst(ifu_inst),
      .out_pc(ifu_pc),
      .out_flush_pipeline(flush_pipeline),

      .prev_valid(wbu_valid),
      .next_ready(idu_ready),
      .out_valid (ifu_valid),
      .out_ready (ifu_ready),

      .out_ifu_araddr(ifu_araddr),
      .out_ifu_arvalid(ifu_arvalid),
      .out_ifu_required(ifu_required),
      .ifu_rdata(bus_ifu_rdata),
      .ifu_rvalid(bus_ifu_rvalid),

      .reset(reset)
  );

  // IDU (Instruction Decode Unit)
  ysyx_idu idu (
      .clock(clock),

      .inst(ifu_inst),
      .rdata1(reg_rdata1),
      .rdata2(reg_rdata2),
      .pc(ifu_pc),

      .exu_valid(exu_valid),
      .exu_forward(exu_reg_wdata),
      .exu_forward_rd((exu_rd)),

      .idu_if(idu_if),

      .out_rs1(idu_rs1),
      .out_rs2(idu_rs2),

      .rf_table(reg_rf_table),

      .prev_valid(ifu_valid && flush_pipeline == 0),
      .next_ready(exu_ready),
      .out_valid (idu_valid),
      .out_ready (idu_ready),

      .reset(reset)
  );

  // EXU (EXecution Unit)
  ysyx_exu exu (
      .clock(clock),

      .idu_if(idu_if),

      .out_inst(exu_inst),
      .out_pc  (exu_pc),

      .out_reg_wdata  (exu_reg_wdata),
      .out_load_retire(exu_load_retire),

      .out_npc_wdata(exu_npc_wdata),
      .out_branch_change(exu_branch_change),
      .out_branch_retire(exu_branch_retire),

      .out_ebreak(exu_ebreak),
      .out_rd((exu_rd)),

      .prev_valid(idu_valid && flush_pipeline == 0),
      .next_ready(wbu_ready),
      .out_valid (exu_valid),
      .out_ready (exu_ready),

      // to lsu
      .out_ren(exu_ren),
      .out_wen(exu_wen),
      .out_rwaddr(exu_rwaddr),
      .out_lsu_avalid(exu_lsu_avalid),
      .out_alu_op(exu_alu_op),
      .out_lsu_mem_wdata(exu_lsu_wdata),

      // from lsu
      .lsu_rdata(lsu_rdata),
      .lsu_exu_rvalid(lsu_exu_rvalid),
      .lsu_exu_wready(lsu_exu_wready),

      .reset(reset)
  );

  // WBU (Write Back Unit)
  ysyx_wbu wbu (
      .clock(clock),

      .inst(exu_inst),
      .pc(exu_pc),
      .ebreak(exu_ebreak),

      .npc_wdata(exu_npc_wdata),
      .branch_change(exu_branch_change),
      .branch_retire(exu_branch_retire),

      .out_npc(wbu_npc),
      .out_change(wbu_pc_change),
      .out_retire(wbu_pc_retire),

      .prev_valid(exu_valid && flush_pipeline == 0),
      .next_ready(ifu_ready),
      .out_valid (wbu_valid),
      .out_ready (wbu_ready),

      .reset(reset)
  );

  ysyx_reg regs (
      .clock(clock),

      .idu_valid(idu_valid && exu_ready),
      .rd(idu_if.rd),

      .bad_speculation(flush_pipeline),
      .reg_write_en(exu_valid && flush_pipeline == 0),
      .waddr((exu_rd)),
      .wdata(exu_reg_wdata),

      .s1addr(idu_rs1),
      .s2addr(idu_rs2),

      .out_rf_table(reg_rf_table),
      .out_src1(reg_rdata1),
      .out_src2(reg_rdata2),

      .reset(reset)
  );

  // LSU (Load/Store Unit)
  ysyx_lsu lsu (
      .clock(clock),

      // from exu
      .addr(exu_rwaddr),
      .ren(exu_ren),
      .wen(exu_wen),
      .lsu_avalid(exu_lsu_avalid),
      .alu_op(exu_alu_op),
      .wdata(exu_lsu_wdata),
      // to exu
      .out_rdata(lsu_rdata),
      .out_rvalid(lsu_exu_rvalid),
      .out_wready(lsu_exu_wready),

      // to-from bus load
      .out_lsu_araddr(lsu_araddr),
      .out_lsu_arvalid(lsu_arvalid),
      .out_lsu_rstrb(lsu_rstrb),
      .bus_rdata(bus_lsu_rdata),
      .lsu_rvalid(bus_lsu_rvalid),

      // to-from bus store
      .out_lsu_awaddr(lsu_awaddr),
      .out_lsu_awvalid(lsu_awvalid),
      .out_lsu_wdata(lsu_wdata),
      .out_lsu_wstrb(lsu_wstrb),
      .out_lsu_wvalid(lsu_wvalid),
      .lsu_wready(bus_lsu_wready),

      .reset(reset)
  );

  ysyx_bus bus (
      .clock(clock),

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

      .ifu_araddr(ifu_araddr),
      .ifu_arvalid(ifu_arvalid),
      .ifu_required(ifu_required),
      .out_ifu_rdata(bus_ifu_rdata),
      .out_ifu_rvalid(bus_ifu_rvalid),

      .lsu_araddr(lsu_araddr),
      .lsu_arvalid(lsu_arvalid),
      .lsu_rstrb(lsu_rstrb),
      .out_lsu_rdata(bus_lsu_rdata),
      .out_lsu_rvalid(bus_lsu_rvalid),

      .lsu_awaddr(lsu_awaddr),
      .lsu_awvalid(lsu_awvalid),
      .lsu_wdata(lsu_wdata),
      .lsu_wstrb(lsu_wstrb),
      .lsu_wvalid(lsu_wvalid),
      .out_lsu_wready(bus_lsu_wready),

      .reset(reset)
  );

endmodule  // ysyx

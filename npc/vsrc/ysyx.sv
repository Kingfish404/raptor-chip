`include "ysyx.svh"
`include "ysyx_if.svh"
`include "ysyx_soc.svh"
`include "ysyx_dpi_c.svh"

module ysyx (
    input clock,
    input reset,

    // AXI4 Slave
    input [1:0] io_slave_arburst,
    input [2:0] io_slave_arsize,
    input [7:0] io_slave_arlen,
    input [3:0] io_slave_arid,
    input [ADDR_W-1:0] io_slave_araddr,
    input io_slave_arvalid,
    output reg io_slave_arready,

    output reg [3:0] io_slave_rid,
    output reg io_slave_rlast,
    output reg [63:0] io_slave_rdata,
    output reg [1:0] io_slave_rresp,
    output reg io_slave_rvalid,
    input io_slave_rready,

    input [1:0] io_slave_awburst,
    input [2:0] io_slave_awsize,
    input [7:0] io_slave_awlen,
    input [3:0] io_slave_awid,
    input [ADDR_W-1:0] io_slave_awaddr,
    input io_slave_awvalid,
    output reg io_slave_awready,

    input io_slave_wlast,
    input [63:0] io_slave_wdata,
    input [7:0] io_slave_wstrb,
    input io_slave_wvalid,
    output reg io_slave_wready,

    output reg [3:0] io_slave_bid,
    output reg [1:0] io_slave_bresp,
    output reg io_slave_bvalid,
    input io_slave_bready,

    // AXI4 Master
    output [1:0] io_master_arburst,
    output [2:0] io_master_arsize,
    output [7:0] io_master_arlen,
    output [3:0] io_master_arid,
    output [ADDR_W-1:0] io_master_araddr,
    output io_master_arvalid,
    input reg io_master_arready,

    input reg [3:0] io_master_rid,
    input reg io_master_rlast,
    input reg [63:0] io_master_rdata,
    input reg [1:0] io_master_rresp,
    input reg io_master_rvalid,
    output io_master_rready,

    output [1:0] io_master_awburst,
    output [2:0] io_master_awsize,
    output [7:0] io_master_awlen,
    output [3:0] io_master_awid,
    output [ADDR_W-1:0] io_master_awaddr,
    output io_master_awvalid,
    input reg io_master_awready,

    output io_master_wlast,
    output [63:0] io_master_wdata,
    output [7:0] io_master_wstrb,
    output io_master_wvalid,
    input reg io_master_wready,

    input reg [3:0] io_master_bid,
    input reg [1:0] io_master_bresp,
    input reg io_master_bvalid,
    output io_master_bready,

    input io_interrupt
);
  parameter bit [7:0] DATA_W = `YSYX_W_WIDTH;
  parameter bit [7:0] ADDR_W = `YSYX_W_WIDTH;
  parameter bit [7:0] REG_ADDR_W = 4;

  // IFU out
  wire [31:0] ifu_inst;
  wire [DATA_W-1:0] ifu_pc;
  wire ifu_speculation;
  wire ifu_bad_speculation, ifu_good_speculation;
  wire ifu_valid, ifu_ready;
  // IFU out bus
  wire [DATA_W-1:0] ifu_araddr;
  wire ifu_arvalid, ifu_required;

  // IDU out
  idu_pipe_if idu_if (.clk(clock));
  wire idu_valid, idu_ready;
  wire [REG_ADDR_W-1:0] idu_rs1, idu_rs2;

  // EXU out
  wire [31:0] exu_inst, exu_pc;
  wire [DATA_W-1:0] exu_reg_wdata;
  wire [DATA_W-1:0] exu_npc_wdata;
  wire exu_branch_change, exu_branch_retire, exu_load_retire;
  wire exu_ebreak;
  wire [REG_ADDR_W-1:0] exu_rd;
  wire exu_valid, exu_ready;
  // EXU out lsu
  wire exu_ren, exu_wen;
  wire [DATA_W-1:0] exu_rwaddr;
  wire exu_lsu_avalid;
  wire [3:0] exu_alu_op;
  wire [DATA_W-1:0] exu_lsu_wdata;

  // WBU out
  wire [31:0] wbu_pc;
  wire wbu_valid, wbu_ready;

  // pc out
  wire [DATA_W-1:0] pc_npc;
  wire pc_change, pc_retire;

  // reg out
  wire [16-1:0] reg_rf_table;
  wire [DATA_W-1:0] reg_rdata1, reg_rdata2;

  // lsu out
  wire [DATA_W-1:0] lsu_rdata;
  wire lsu_exu_rvalid;
  wire lsu_exu_wready;
  // lsu out load
  wire [DATA_W-1:0] lsu_araddr;
  wire lsu_arvalid;
  wire [7:0] lsu_rstrb;
  // lsu out store
  wire [DATA_W-1:0] lsu_awaddr;
  wire lsu_awvalid;
  wire [DATA_W-1:0] lsu_wdata;
  wire [7:0] lsu_wstrb;
  wire lsu_wvalid;

  // bus out
  wire [DATA_W-1:0] bus_ifu_rdata;
  wire bus_ifu_rvalid;
  wire [DATA_W-1:0] bus_lsu_rdata;
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

      .npc(pc_npc),
      .pc(wbu_pc),
      .pc_change(pc_change),
      .pc_retire(pc_retire),
      .load_retire(exu_load_retire),

      .inst_o(ifu_inst),
      .pc_o(ifu_pc),
      .speculation_o(ifu_speculation),
      .bad_speculation_o(ifu_bad_speculation),
      .good_speculation_o(ifu_good_speculation),

      .prev_valid(wbu_valid),
      .next_ready(idu_ready),
      .valid_o(ifu_valid),
      .ready_o(ifu_ready),

      .ifu_araddr_o(ifu_araddr),
      .ifu_arvalid_o(ifu_arvalid),
      .ifu_required_o(ifu_required),
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
      .speculation(ifu_speculation),

      .exu_valid(exu_valid),
      .exu_forward(exu_reg_wdata),
      .exu_forward_rd((exu_rd)),

      .idu_if(idu_if),

      .rs1_o(idu_rs1),
      .rs2_o(idu_rs2),

      .rf_table(reg_rf_table),

      .prev_valid(ifu_valid & ifu_bad_speculation == 0),
      .next_ready(exu_ready),
      .valid_o(idu_valid),
      .ready_o(idu_ready),

      .reset(reset)
  );

  // EXU (EXecution Unit)
  ysyx_exu exu (
      .clock(clock),

      .idu_if(idu_if),

      .inst_o(exu_inst),
      .pc_o  (exu_pc),

      .reg_wdata_o(exu_reg_wdata),
      .npc_wdata_o(exu_npc_wdata),
      .branch_change_o(exu_branch_change),
      .branch_retire_o(exu_branch_retire),
      .load_retire_o(exu_load_retire),

      .ebreak_o(exu_ebreak),
      .rd_o((exu_rd)),

      .prev_valid(idu_valid & ifu_bad_speculation == 0),
      .next_ready(wbu_ready),
      .valid_o(exu_valid),
      .ready_o(exu_ready),

      // to lsu
      .ren_o(exu_ren),
      .wen_o(exu_wen),
      .rwaddr_o(exu_rwaddr),
      .lsu_avalid_o(exu_lsu_avalid),
      .alu_op_o(exu_alu_op),
      .lsu_mem_wdata_o(exu_lsu_wdata),

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
      .pc  (exu_pc),

      .ebreak(exu_ebreak),
      .pc_o  (wbu_pc),

      .prev_valid(exu_valid & ifu_bad_speculation == 0),
      .next_ready(ifu_ready),
      .valid_o(wbu_valid),
      .ready_o(wbu_ready),

      .reset(reset)
  );

  ysyx_pc pc_unit (
      .clock(clock),

      .good_speculation(ifu_good_speculation),
      .bad_speculation(ifu_bad_speculation),
      .pc_ifu(ifu_pc),

      .npc_wdata(exu_npc_wdata),
      .branch_change(exu_branch_change),
      .branch_retire(exu_branch_retire),
      .out_npc(pc_npc),
      .out_change(pc_change),
      .out_retire(pc_retire),

      .prev_valid(exu_valid),

      .reset(reset)
  );

  ysyx_reg regs (
      .clock(clock),

      .idu_valid(idu_valid & exu_ready),
      .rd(idu_if.rd),

      .bad_speculation(ifu_bad_speculation),
      .reg_write_en(exu_valid & ifu_bad_speculation == 0),
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
      .rdata_o(lsu_rdata),
      .rvalid_o(lsu_exu_rvalid),
      .wready_o(lsu_exu_wready),

      // to-from bus load
      .lsu_araddr_o(lsu_araddr),
      .lsu_arvalid_o(lsu_arvalid),
      .lsu_rstrb_o(lsu_rstrb),
      .bus_rdata(bus_lsu_rdata),
      .lsu_rvalid(bus_lsu_rvalid),

      // to-from bus store
      .lsu_awaddr_o(lsu_awaddr),
      .lsu_awvalid_o(lsu_awvalid),
      .lsu_wdata_o(lsu_wdata),
      .lsu_wstrb_o(lsu_wstrb),
      .lsu_wvalid_o(lsu_wvalid),
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

      .ifu_araddr  (ifu_araddr),
      .ifu_arvalid (ifu_arvalid),
      .ifu_required(ifu_required),
      .ifu_rdata_o (bus_ifu_rdata),
      .ifu_rvalid_o(bus_ifu_rvalid),

      .lsu_araddr(lsu_araddr),
      .lsu_arvalid(lsu_arvalid),
      .lsu_rstrb(lsu_rstrb),
      .lsu_rdata_o(bus_lsu_rdata),
      .lsu_rvalid_o(bus_lsu_rvalid),

      .lsu_awaddr(lsu_awaddr),
      .lsu_awvalid(lsu_awvalid),
      .lsu_wdata(lsu_wdata),
      .lsu_wstrb(lsu_wstrb),
      .lsu_wvalid(lsu_wvalid),
      .lsu_wready_o(bus_lsu_wready),

      .reset(reset)
  );

endmodule  // top

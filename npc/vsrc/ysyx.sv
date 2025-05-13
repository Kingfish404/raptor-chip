`include "ysyx.svh"
`include "ysyx_if.svh"
`include "ysyx_soc.svh"
`include "ysyx_dpi_c.svh"

/**
 ------------------------------------------------------------
 RISC-V processor pipeline
 has the following (conceptual) stages:
 ------------------------------------------------------------
 in-order      | IFU - Instruction Fetch Unit
 issue         | IDU - Instruction Decode Unit
 --------------+ IQU - Instruction Queue Unit
 out-of-order  :
 execution     : EXU - Execution Unit
 --------------+
 in-order      | IQU - Instruction Queue Unit
 commit        | WBU - Write Back Unit
 ------------------------------------------------------------
 Stages (`=>' split each stage):
 [
  frontend (in-order and speculative issue):
        v- [BUS <-load- AXI4]
    IFU[l1i] =issue=> IDU =issue=> IQU[uop]
        ^- bpu[btb,btb_jal]
    IQU[uop] -dispatch-> IQU[rob]
             =dispatch=> EXU[rs ]
  backend  (out-of-order execution):
    EXU[rs]  =write-back=> IQU[rob]
        ^- LSU[l1d] <-load/store-> [BUS <-load/store-> AXI4]
        |- MUL :mult/div
  frontend (in-order commit):
    IQU[rob] =commit=>
    WBU[rf ] =resolve-branch=> frontend: IFU[pc,bpu]
 ]
 ------------------------------------------------------------
 See ./include/ysyx.svh for more details.
 */
module ysyx #(
    parameter bit [7:0] XLEN = `YSYX_XLEN
) (
    input clock,

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
  logic flush_pipeline;
  logic ifu_valid, ifu_ready;
  // IFU out bus
  logic [XLEN-1:0] ifu_araddr;
  logic ifu_arvalid, ifu_bus_lock;

  // IDU out
  idu_pipe_if idu_if ();
  logic idu_valid, idu_ready;

  // IQU out
  idu_pipe_if iqu_exu_if ();
  exu_pipe_if iqu_wbu_if ();
  exu_pipe_if iqu_cm_if ();
  logic iqu_valid, iqu_ready;
  logic [4:0] iqu_rs1, iqu_rs2;

  // EXU out
  exu_pipe_if exu_wb_if ();
  logic exu_ready;
  // EXU out lsu
  logic exu_ren, exu_wen;
  logic [XLEN-1:0] exu_rwaddr;
  logic [4:0] exu_alu_op;
  logic [XLEN-1:0] exu_lsu_wdata;

  // WBU out
  logic wbu_valid;
  logic [XLEN-1:0] wbu_npc;
  logic [XLEN-1:0] wbu_rpc;
  logic wbu_retire;

  // Reg out
  logic [XLEN-1:0] reg_rdata1, reg_rdata2;

  // lsu out
  logic [XLEN-1:0] lsu_rdata;
  logic lsu_exu_rvalid;
  logic lsu_exu_wready;
  // lsu out load
  logic [XLEN-1:0] lsu_araddr;
  logic lsu_arvalid;
  logic [7:0] lsu_rstrb;
  // lsu out store
  logic [XLEN-1:0] lsu_awaddr;
  logic lsu_awvalid;
  logic [XLEN-1:0] lsu_wdata;
  logic [7:0] lsu_wstrb;
  logic lsu_wvalid;

  // bus out
  logic bus_ifu_ready;
  logic [XLEN-1:0] bus_ifu_rdata;
  logic bus_ifu_rvalid;
  logic [XLEN-1:0] bus_lsu_rdata;
  logic bus_lsu_rvalid;
  logic bus_lsu_wready;

  // IFU (Instruction Fetch Unit)
  ysyx_ifu ifu (
      .clock(clock),

      // <= wbu
      .npc(wbu_npc),
      .cpc(wbu_rpc),
      .sys_retire(wbu_retire),

      .out_inst(ifu_inst),
      .out_pc(ifu_pc),
      .out_pnpc(ifu_pnpc),
      .flush_pipeline(flush_pipeline),

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
      .idu_if(idu_if),

      .prev_valid(ifu_valid),
      .next_ready(iqu_ready),
      .out_valid (idu_valid),
      .out_ready (idu_ready),

      .reset(reset || flush_pipeline)
  );

  // IQU (Instruction Queue Unit)
  ysyx_iqu iqu (
      .clock(clock),

      .idu_if(idu_if),
      .iqu_exu_if(iqu_exu_if),

      .exu_wb_if(exu_wb_if),

      .iqu_wbu_if(iqu_wbu_if),

      .out_rs1(iqu_rs1),
      .out_rs2(iqu_rs2),
      .rdata1 (reg_rdata1),
      .rdata2 (reg_rdata2),

      // => exu (commit)
      .iqu_cm_if(iqu_cm_if),

      .flush_pipeline(flush_pipeline),

      .prev_valid(idu_valid),
      .next_ready(exu_ready),
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
      .out_wen(exu_wen),
      .out_rwaddr(exu_rwaddr),
      .out_alu_op(exu_alu_op),
      .out_lsu_mem_wdata(exu_lsu_wdata),
      // <= lsu
      .lsu_rdata(lsu_rdata),
      .lsu_exu_rvalid(lsu_exu_rvalid),
      .lsu_exu_wready(lsu_exu_wready),

      // => iqu & (wbu)
      .exu_wb_if(exu_wb_if),

      // <= iqu
      .iqu_cm_if(iqu_cm_if),

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

      .npc_wdata (iqu_wbu_if.npc),
      .sys_retire(iqu_wbu_if.sys_retire),

      .out_npc(wbu_npc),
      .out_rpc(wbu_rpc),
      .out_retire(wbu_retire),

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

      // from exu
      .rwaddr(exu_rwaddr),
      .alu_op(exu_alu_op),
      .ren(exu_ren),
      .wen(exu_wen),
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
      // lsu load
      .lsu_araddr(lsu_araddr),
      .lsu_arvalid(lsu_arvalid),
      .lsu_rstrb(lsu_rstrb),
      .out_lsu_rdata(bus_lsu_rdata),
      .out_lsu_rvalid(bus_lsu_rvalid),
      // lsu store
      .lsu_awaddr(lsu_awaddr),
      .lsu_awvalid(lsu_awvalid),
      .lsu_wdata(lsu_wdata),
      .lsu_wstrb(lsu_wstrb),
      .lsu_wvalid(lsu_wvalid),
      .out_lsu_wready(bus_lsu_wready),

      .reset(reset)
  );

endmodule

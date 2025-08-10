`ifndef YSYX_IF_SVH
`define YSYX_IF_SVH
`include "ysyx.svh"
`include "ysyx_id_if.svh"
`include "ysyx_rn_if.svh"

interface ifu_bpu_if #(
    parameter int XLEN = `YSYX_XLEN,
    parameter int PHT_SIZE = `YSYX_PHT_SIZE,
    parameter int BTB_SIZE = `YSYX_BTB_SIZE,
    parameter int RSB_SIZE = `YSYX_RSB_SIZE
);
  logic [XLEN-1:0] pc;
  logic [XLEN-1:0] inst;

  logic [XLEN-1:0] npc;
  logic taken;

  modport out(output pc, inst, input npc, taken);
  modport in(input pc, inst, output npc, taken);
endinterface

interface ifu_l1i_if #(
    parameter int XLEN = `YSYX_XLEN,
    parameter int L1I_LEN = `YSYX_L1I_LEN,
    parameter int L1I_LINE_LEN = `YSYX_L1I_LINE_LEN
);
  logic [XLEN-1:0] pc;
  logic invalid;
  logic [31:0] inst;

  logic valid;

  modport master(output pc, invalid, input inst, valid);
  modport slave(input pc, invalid, output inst, valid);
endinterface

interface ifu_idu_if #(
    parameter int XLEN = `YSYX_XLEN
);
  logic [31:0] inst;
  logic [XLEN-1:0] pc;
  logic [XLEN-1:0] pnpc;

  logic valid;
  logic ready;

  modport master(output inst, pc, pnpc, valid, input ready);
  modport slave(input inst, pc, pnpc, valid, output ready);
endinterface

interface rou_reg_if #(
    parameter int XLEN = `YSYX_XLEN
);
  logic [4:0] rs1;
  logic [4:0] rs2;

  logic [XLEN-1:0] src1;
  logic [XLEN-1:0] src2;

  modport master(output rs1, rs2, input src1, src2);
  modport slave(input rs1, rs2, output src1, src2);
endinterface

interface exu_lsu_if #(
    parameter int XLEN = `YSYX_XLEN
);
  logic rvalid;
  logic [XLEN-1:0] raddr;
  logic [4:0] ralu;
  logic [XLEN-1:0] pc;

  logic [XLEN-1:0] rdata;
  logic rready;

  modport master(output rvalid, raddr, ralu, pc, input rdata, rready);
  modport slave(input rvalid, raddr, ralu, pc, output rdata, rready);
endinterface

interface exu_csr_if #(
    parameter bit [7:0] R_W  = 12,
    parameter bit [7:0] XLEN = `YSYX_XLEN
);
  logic [ R_W-1:0] raddr;

  logic [XLEN-1:0] rdata;
  logic [XLEN-1:0] mtvec;
  logic [XLEN-1:0] mepc;

  modport master(output raddr, input rdata, mtvec, mepc);
  modport slave(input raddr, output rdata, mtvec, mepc);
endinterface

interface rou_lsu_if #(
    parameter int XLEN = `YSYX_XLEN
);
  logic store;
  logic [4:0] alu;
  logic [XLEN-1:0] sq_waddr;
  logic [XLEN-1:0] sq_wdata;
  logic sq_ready;
  logic [XLEN-1:0] pc;

  logic valid;

  modport in(input store, alu, sq_waddr, sq_wdata, pc, valid, output sq_ready);
  modport out(output store, alu, sq_waddr, sq_wdata, pc, valid, input sq_ready);
endinterface

interface rou_csr_if #(
    parameter int XLEN = `YSYX_XLEN
);
  logic [XLEN-1:0] pc;

  logic csr_wen;
  logic [XLEN-1:0] csr_wdata;
  logic [11:0] csr_addr;

  logic ecall;
  logic ebreak;
  logic mret;

  logic trap;
  logic [XLEN-1:0] tval;
  logic [XLEN-1:0] cause;

  logic valid;

  modport in(
      input pc,
      input csr_wen, csr_wdata, csr_addr, ecall, ebreak, mret,
      input trap, tval, cause,
      input valid
  );
  modport out(
      output pc,
      output csr_wen, csr_wdata, csr_addr, ecall, ebreak, mret,
      output trap, tval, cause,
      output valid
  );
endinterface

interface lsu_l1d_if #(
    parameter int XLEN = `YSYX_XLEN,
    parameter int L1D_LEN = `YSYX_L1D_LEN
);
  logic [XLEN-1:0] raddr;
  logic [4:0] ralu;
  logic rvalid;

  logic [XLEN-1:0] rdata;
  logic rready;

  logic [XLEN-1:0] waddr;
  logic [4:0] walu;
  logic wvalid;
  logic [XLEN-1:0] wdata;

  modport master(
      output raddr, ralu, rvalid,
      input rdata, rready,
      output waddr, walu, wvalid, wdata
  );
  modport slave(input raddr, ralu, rvalid, output rdata, rready, input waddr, walu, wvalid, wdata);
endinterface

interface l1i_bus_if #(
    parameter int XLEN = `YSYX_XLEN
);
  // load
  logic arvalid;
  logic [XLEN-1:0] araddr;
  logic rready;

  logic [XLEN-1:0] rdata;
  logic rvalid;
  logic rlast;

  modport master(output arvalid, araddr, input rready, rdata, rvalid, rlast);
  modport slave(input arvalid, araddr, output rready, rdata, rvalid, rlast);
endinterface

interface l1d_bus_if #(
    parameter int XLEN = `YSYX_XLEN
);
  // load
  logic arvalid;
  logic [XLEN-1:0] araddr;
  logic [7:0] rstrb;
  logic rready;

  logic [XLEN-1:0] rdata;
  logic rvalid;
  logic rlast;

  // store
  logic awvalid;
  logic [XLEN-1:0] awaddr;
  logic wvalid;
  logic [XLEN-1:0] wdata;
  logic [7:0] wstrb;
  logic wready;

  modport master(
      output arvalid, araddr, rstrb,
      input rready,
      input rdata, rvalid, rlast,

      output awvalid, awaddr, wvalid, wdata, wstrb,
      input wready
  );
  modport slave(
      input arvalid, araddr, rstrb,
      output rready,
      output rdata, rvalid, rlast,

      input awvalid, awaddr, wvalid, wdata, wstrb,
      output wready
  );
endinterface

interface cmu_pipe_if #(
    parameter unsigned RLEN = `YSYX_REG_LEN,
    parameter int XLEN = `YSYX_XLEN
);
  logic [XLEN-1:0] rpc;
  logic [XLEN-1:0] cpc;
  logic [RLEN-1:0] rd;

  logic jen;
  logic ben;

  logic fence_time;
  logic fence_i;

  logic flush_pipe;

  modport in(input rpc, cpc, rd, jen, ben, fence_time, fence_i, flush_pipe);
  modport out(output rpc, cpc, rd, jen, ben, fence_time, fence_i, flush_pipe);
endinterface

`endif

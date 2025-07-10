`ifndef YSYX_IF_SVH
`define YSYX_IF_SVH
`include "ysyx.svh"
`include "ysyx_pipe_if.svh"

interface ifu_idu_if #(
    parameter int XLEN = `YSYX_XLEN
);
  logic [31:0] inst;
  logic [XLEN-1:0] pc;
  logic [XLEN-1:0] pnpc;

  logic valid;

  modport master(output inst, pc, pnpc, valid);
  modport slave(input inst, pc, pnpc, valid);
endinterface

interface ifu_bus_if #(
    parameter int XLEN = `YSYX_XLEN
);
  logic arvalid;
  logic [XLEN-1:0] araddr;

  logic bus_ready;
  logic rready;
  logic [XLEN-1:0] rdata;

  modport master(output arvalid, araddr, input bus_ready, rready, rdata);
  modport slave(input arvalid, araddr, output bus_ready, rready, rdata);
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

interface exu_rou_if #(
    parameter int XLEN = `YSYX_XLEN
);
  logic [31:0] inst;
  logic [XLEN-1:0] pc;
  logic [XLEN-1:0] npc;

  logic [$clog2(`YSYX_ROB_SIZE):0] dest;
  logic [XLEN-1:0] result;

  // csr
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
      input inst, pc, npc,
      input dest, result, ebreak,
      input csr_wen, csr_wdata, csr_addr, ecall, mret,
      input trap, tval, cause,
      input valid
  );
  modport out(
      output inst, pc, npc,
      output dest, result, ebreak,
      output csr_wen, csr_wdata, csr_addr, ecall, mret,
      output trap, tval, cause,
      output valid
  );
endinterface

interface exu_ioq_rou_if #(
    parameter int XLEN = `YSYX_XLEN
);
  logic [31:0] inst;
  logic [XLEN-1:0] pc;
  logic [XLEN-1:0] npc;

  logic [XLEN-1:0] result;
  logic [$clog2(`YSYX_ROB_SIZE):0] dest;

  logic wen;
  logic [4:0] alu;
  logic [XLEN-1:0] sq_waddr;
  logic [XLEN-1:0] sq_wdata;

  logic valid;

  modport in(input inst, pc, npc, result, dest, wen, alu, sq_waddr, sq_wdata, input valid);
  modport out(output inst, pc, npc, result, dest, wen, alu, sq_waddr, sq_wdata, output valid);
endinterface

interface exu_lsu_if #(
    parameter int XLEN = `YSYX_XLEN
);
  logic arvalid;
  logic [XLEN-1:0] raddr;
  logic [4:0] ralu;
  logic [XLEN-1:0] pc;

  logic [XLEN-1:0] rdata;
  logic rready;

  modport master(output arvalid, raddr, ralu, pc, input rdata, rready);
  modport slave(input arvalid, raddr, ralu, pc, output rdata, rready);
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
  logic [XLEN-1:0] pc;

  logic valid;

  modport in(input store, alu, sq_waddr, sq_wdata, pc, input valid);
  modport out(output store, alu, sq_waddr, sq_wdata, pc, output valid);
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

interface rou_wbu_if #(
    parameter int XLEN = `YSYX_XLEN
);
  logic [4:0] rd;
  logic [XLEN-1:0] wdata;

  logic [31:0] inst;
  logic [XLEN-1:0] pc;

  logic [XLEN-1:0] npc;
  logic sys_retire;
  logic jen;
  logic ben;

  logic ebreak;
  logic fence_time;
  logic fence_i;

  logic flush_pipe;

  logic valid;

  modport in(
      input rd, wdata, inst, pc,
      input npc, sys_retire, jen, ben,
      input ebreak, fence_time, fence_i, flush_pipe,
      input valid
  );
  modport out(
      output rd, wdata, inst, pc,
      output npc, sys_retire, jen, ben,
      output ebreak, fence_time, fence_i, flush_pipe,
      output valid
  );
endinterface

interface lsu_bus_if #(
    parameter int XLEN = `YSYX_XLEN
);
  // load
  logic arvalid;
  logic [XLEN-1:0] araddr;
  logic [7:0] rstrb;
  logic rvalid;
  logic [XLEN-1:0] rdata;
  // store
  logic awvalid;
  logic [XLEN-1:0] awaddr;
  logic [7:0] wstrb;
  logic wvalid;
  logic [XLEN-1:0] wdata;
  logic wready;

  modport master(
      output araddr, arvalid, rstrb,
      output awaddr, awvalid, wdata, wstrb, wvalid,
      input rdata, rvalid, wready
  );
  modport slave(
      input araddr, arvalid, rstrb,
      input awaddr, awvalid, wdata, wstrb, wvalid,
      output rdata, rvalid, wready
  );
endinterface

`endif

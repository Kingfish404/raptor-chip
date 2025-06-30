`ifndef YSYX_IF_SVH
`define YSYX_IF_SVH
`include "ysyx.svh"

interface idu_pipe_if;
  logic [4:0] alu;
  logic jen;
  logic ben;
  logic wen;
  logic ren;
  logic atom;

  logic system;
  logic ecall;
  logic ebreak;
  logic fence_i;
  logic fence_time;
  logic mret;
  logic [2:0] csr_csw;

  logic trap;
  logic [`YSYX_XLEN-1:0] tval;
  logic [`YSYX_XLEN-1:0] cause;

  logic [4:0] rd;
  logic [31:0] imm;
  logic [31:0] op1;
  logic [31:0] op2;
  logic [4:0] rs1;
  logic [4:0] rs2;

  logic [$clog2(`YSYX_ROB_SIZE):0] qj;
  logic [$clog2(`YSYX_ROB_SIZE):0] qk;
  logic [$clog2(`YSYX_ROB_SIZE):0] dest;

  logic [`YSYX_XLEN-1:0] pnpc;

  logic [31:0] inst;
  logic [`YSYX_XLEN-1:0] pc;

  modport in(
      input alu, jen, ben, wen, ren, atom,
      input system, ecall, ebreak, mret, csr_csw,
      input trap, tval, cause,
      input fence_i, fence_time,
      input rd, imm, op1, op2, rs1, rs2,
      input qj, qk, dest,
      input pnpc,
      input inst,
      input pc
  );
  modport out(
      output alu, jen, ben, wen, ren, atom,
      output system, ecall, ebreak, mret, csr_csw,
      output trap, tval, cause,
      output fence_i, fence_time,
      output rd, imm, op1, op2, rs1, rs2,
      output qj, qk, dest,
      output pnpc,
      output inst,
      output pc
  );
endinterface

interface exu_pipe_if;
  logic [$clog2(`YSYX_RS_SIZE)-1:0] rs_idx;

  logic [4:0] rd;
  logic [31:0] inst;
  logic [`YSYX_XLEN-1:0] pc;

  logic [$clog2(`YSYX_ROB_SIZE):0] dest;
  logic [`YSYX_XLEN-1:0] result;

  // wbu
  logic [`YSYX_XLEN-1:0] npc;
  logic sys_retire;
  logic jen;
  logic ben;

  // csr
  logic csr_wen;
  logic [`YSYX_XLEN-1:0] csr_wdata;
  logic [11:0] csr_addr;

  logic ecall;
  logic ebreak;
  logic fence_i;
  logic mret;

  logic trap;
  logic [`YSYX_XLEN-1:0] tval;
  logic [`YSYX_XLEN-1:0] cause;

  // store
  logic [`YSYX_XLEN-1:0] sq_waddr;
  logic [`YSYX_XLEN-1:0] sq_wdata;

  logic valid;

  modport in(
      input rs_idx,
      input rd, inst, pc,
      input dest, result, npc, sys_retire, jen, ben, ebreak,
      input fence_i,
      input csr_wen, csr_wdata, csr_addr, ecall, mret,
      input trap, tval, cause,
      input sq_waddr, sq_wdata,
      input valid
  );
  modport out(
      output rs_idx,
      output rd, inst, pc,
      output dest, result, npc, sys_retire, jen, ben, ebreak,
      output fence_i,
      output csr_wen, csr_wdata, csr_addr, ecall, mret,
      output trap, tval, cause,
      output sq_waddr, sq_wdata,
      output valid
  );
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

interface rou_lsu_if;
  logic store;
  logic [4:0] alu;
  logic [`YSYX_XLEN-1:0] sq_waddr;
  logic [`YSYX_XLEN-1:0] sq_wdata;

  logic valid;

  modport in(input store, alu, sq_waddr, sq_wdata, input valid);
  modport out(output store, alu, sq_waddr, sq_wdata, output valid);

endinterface  //cm_store_if

interface wbu_pipe_if;
  logic [`YSYX_XLEN-1:0] npc;
  logic [`YSYX_XLEN-1:0] rpc;
  logic jen;
  logic ben;
  logic sys_retire;

  modport in(input npc, rpc, jen, ben, sys_retire);
  modport out(output npc, rpc, jen, ben, sys_retire);

endinterface  //wbu_pipe_if

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

endinterface  //lsu_pipe_if

`endif
